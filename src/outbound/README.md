# Outbound TCP 编程模型

## 决策树

```
需要出站 TCP → MySQL / Redis / PostgreSQL / NATS ?

  ├─ 小操作 (写入, 小查询, NATS publish; 结果 < 64KB)
  │   → 共享 Ring A, Next.go fiber
  │   → 一个 fiber 完成 connect → write → read → respond
  │   → 优点: 零额外 ring, 零额外线程, 代码最简
  │
  └─ 大结果/流式/长连接 (MySQL大查询, NATS订阅, Redis SCAN)
      → TcpOutboundRing (独立 ring)
      → attachStream / on_read callback → 持续处理
      → 优点: 不阻塞 IO 线程, 不占 RingB(HTTP)
```

## 模式 1: 共享 Ring A (小操作)

**适用**: 写入、NATS publish、小查询。结果 < 64KB，单次往返。

**原理**: `Next.go` 启动 Fiber（跑在 IO 线程共享栈上）。Fiber 内调用 io_uring connect/read/write，每次 yield，CQE 到达时 resume。

```zig
// 模式 1: Ring A, 小写入
pub fn writeHandler(allocator: Allocator, ctx: *Context) !void {
    const server: *sws.AsyncServer = @ptrCast(@alignCast(ctx.server orelse return));
    const resp = try allocator.create(DeferredResponse);
    resp.* = .{ .server = @ptrCast(server), .conn_id = ctx.conn_id, .allocator = allocator };

    sws.Next.go(WriteCtx, .{ .sql = ctx.query("msg") orelse "", .resp = resp }, execWrite);
    ctx.deferred = true;
}

fn execWrite(c: *WriteCtx, complete: fn) void {
    _ = complete;
    const fd = socket() catch return;
    connectOnRingA(fd, "127.0.0.1", 3306);       // yield → CQE → resume
    writeOnRingA(fd, buildAuthPacket());           // yield
    readOnRingA(fd, buf);                           // yield
    writeOnRingA(fd, buildQueryPacket(c.sql));     // yield
    readOnRingA(fd, buf);                           // yield
    c.resp.json(200, "{\"ok\":true}");
    close(fd);
}
```

**限制**: 共享栈 ~64KB。不要递归，不要大 parser。Fiber yield 后栈可被其他 Fiber 复用。

## 模式 2: TcpOutboundRing (大结果 / 流式 / 长连接)

**适用**: 大查询（> 64KB）、NATS 订阅（长连接）、Redis SCAN。

**原理**: 独立 ring + `tick()` CQE 循环。数据出口二选一：

- `attachStream` → `stream.feed` → WorkerPool 解析
- `on_read` callback → 用户自定义处理

```zig
// 模式 2a: attachStream (MySQL 大查询)
const conn = try mysql_ring.connect("127.0.0.1", 3306);
mysql_ring.attachStream(conn, stream);
// ring.tick() → read CQE → stream.feed → Worker

// 模式 2b: on_read 回调 (NATS 订阅)
const conn = try nats_ring.connect("127.0.0.1", 4222);
conn.on_read = natsOnMessage;
conn.on_read_ctx = app;
try nats_ring.write(conn, "SUB im.msg.push 1\r\n");
// ring.tick() → read CQE → natsOnMessage → 继续读

fn natsOnMessage(ctx: ?*anyopaque, data: []u8) void {
    // 解析 NATS 协议，分发到 handler（非阻塞，< 100µs）
}
```

## 数据出口优先级

```
TcpConn 读 CQE:
  ├─ conn.stream != null  → stream.feed(data)   → WorkerPool
  ├─ conn.on_read != null → callback(data)        → 用户自定义
  └─ 无                    → (忽略, 不自动续读)
```

## 拓扑

```
Ring A:   主服务 (accept/HTTP/WS/Fiber小出站)
Ring B:   HTTP 客户端 (集群内调用)

TcpOutboundRing 实例 (按需创建，用户命名):
  mysql_ring:  MySQL 大查询流式 (attachStream)
  nats_ring:   NATS 订阅 (on_read 回调)
  redis_ring:  Redis SCAN (attachStream)
```

所有协议的订阅/长连接都走同一套 `TcpOutboundRing` API。Ring C/D/E 不存在于框架里——只是用户给实例取的名字。
