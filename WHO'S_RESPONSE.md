# WHO'S RESPONSE? — 出站 TCP 响应归谁

每个写过 io_uring TCP 出站的人都会问: TCP 连接上收到数据,CQE只有 `res` 和 `user_data`,怎么知道
这段字节回应的是哪个请求?

sws 的答案取决于协议和连接模型,分四种情况。

## 1. HTTP Client (sws/src/client/http_client.zig)

```
机制: Fiber 独占连接,串行请求-响应

Fiber {
  cache.getPipe(host,port) → 拿到或新建连接
  stream.write(req)         → 发送 HTTP 请求
  reader.read(&buf)         → 读响应 (yield → CQE → resume)
  parseResponse(buf)        → 解析
  ctx.notify()              → 唤醒调用线程
}

关联: 一条 fiber = 一个 RequestContext = 一个 HTTP 请求
      fiber 串行: write → read → parse → 结束
      连接被 fiber 独占,不存在"两个请求争同一条连接"。
```

⚠️ tiny-cache: 已修复。多槽位连接池, acquire() 标记 borrowed, release() 归还。
   k8s pod 间通信允许多条同 host:port 并发连接。上限 8。

## 2. MySQL (TcpOutboundRing + ChunkStream)

```
机制: MySQL 协议本身是同步的,一条连接一次只跑一个查询

TcpOutboundRing:
  ring.write(conn, query_packet)
  ring.tick() → read CQE → stream.feed(data)
  dispatch → Worker

关联: 一条 TcpConn = 一个 StreamHandle = 一个 ChunkParser
      MySQL 协议约定: COM_QUERY 发送后,必须读完所有结果集(列定义+行+EOF)
      才能发送下一个命令。单连接天然串行。
```

不需要 request/response 匹配——连接级别独占。

## 3. NATS (RingSharedClient + Pipe + Fiber)

```
机制: NATS 协议级 sid 多路复用

Fiber:
  write("SUB im.msg.push sid1\r\n")
  write("SUB im.msg.saved sid2\r\n")

Ring tick → read CQE → parser:
  MSG im.msg.push sid1 256\r\n{payload}\r\n
    → 提取 sid=1 → 匹配 natsOnPush 回调
  MSG im.msg.saved sid2 128\r\n{payload}\r\n
    → 提取 sid=2 → 匹配 natsOnSaved 回调

关联: 多条订阅共享一条 TCP 连接, NATS 协议在 MSG 行自带 sid 字段。
      解析器按 sid 查表,分派到正确的回调。协议级匹配。
```

## 4. TcpOutboundRing (通用模型)

```
机制: 每条 TcpConn 绑定一个数据消费者

TcpConn:
  conn.stream   != null → CQE 数据 → stream.feed()    → WorkerPool
  conn.on_read  != null → CQE 数据 → callback(data)   → 用户自定义
  conn.stream   == null and conn.on_read == null → 忽略

关联: 一个 ring 承载多条连接 (MySQL + NATS + Redis + ...)
      每条连接只有一个消费者 (stream 或 callback)
      不存在"两个消费者抢同一条连接的数据"。
```

## 5. forward.zig (跨 Pod HTTP 转发)

```
机制: 每条消息新建 TCP 连接,用完即关

Worker 线程:
  socket() → connect() → write(req) → read(response) → close()

关联: 一条消息 = 一条 TCP 连接。不复用,不存在串线。
```

## 总结

| 协议 | 关联方式 | 并发安全 |
|------|---------|---------|
| HTTP Client | Fiber 独占连接 (串行 write→read) | ⚠️ tiny-cache 回池需加 borrow 标记 |
| MySQL | 协议同步 (conn 独占) | ✅ |
| NATS | 协议级 sid 匹配 | ✅ |
| TcpOutboundRing (通用) | one conn = one consumer | ✅ |
| forward.zig | 新建连接/消息 | ✅ |

## 原则

sws 不在 TCP 层做 request/response 匹配。TCP 层只保证:

```
一条 TcpConn ↔ 一个 StreamHandle 或一个 callback
```

多路复用交给协议层 (NATS sid / HTTP Content-Length / MySQL sequence number)。
如果协议不支持多路复用,就用一条连接跑一个请求——连接级独占。

这个设计避免了为每个出站帧维护 request_id 和响应队列,让 TcpOutboundRing 保持
零 alloc 零锁的热路径。
