# Bug Report - SWAS Project

## 1. 安全漏洞 (Security Vulnerabilities)

### 1.1 WebSocket 升级缺少 Origin 验证 (高危)
**文件:** `src/ws/upgrade.zig`

WebSocket 握手时没有验证 HTTP `Origin` 头，允许跨站 WebSocket 握手，容易遭受 CSRF 攻击。

```zig
// 当前代码 - isUpgradeRequest 函数没有检查 Origin
pub fn isUpgradeRequest(data: []const u8) bool {
    // 只检查了 Upgrade, Sec-WebSocket-Key, Sec-WebSocket-Version
    // 缺少 Origin 验证
}
```

**影响:** 恶意网站可以诱导用户浏览器向目标服务器发起 WebSocket 连接

**修复建议:** 添加 Origin 头验证逻辑，允许配置的域名白名单

---

### 1.2 WebSocket 缺少 Sec-WebSocket-Protocol 验证 (中危)
**文件:** `src/ws/upgrade.zig`

客户端可以请求子协议但服务器不验证返回的协议是否匹配客户端请求

---

### 1.3 缺少速率限制 (中危)
**文件:** `src/http/async_server.zig`

没有对连接速率、请求频率进行限制，容易遭受 DoS 攻击

---

### 1.4 路径长度检查绕过风险
**文件:** `src/http/http_helpers.zig`

```zig
pub fn getPathFromRequest(buf: []const u8) ?[]const u8 {
    // ...
    if (raw.len == 0 or raw.len > MAX_PATH_LENGTH) return null;
    // 只检查了路径本身，没有检查完整请求行长度
}
```

攻击者可以发送超长 HTTP 请求行绕过 MAX_PATH_LENGTH 限制

---

## 2. 内存/资源问题 (Memory & Resource Issues)

### 2.1 连接关闭时可能存在 use-after-free (高危)
**文件:** `src/http/async_server.zig`

```zig
fn onReadComplete(self: *Self, conn_id: u64, res: i32, ...) {
    if (res <= 0) {
        const conn = self.connections.get(conn_id) orelse return;
        // conn 是从 HashMap 获取的 value，closeConn 会 remove 这个连接
        self.closeConn(conn_id, conn.fd);  // 这里会删除连接
        // 之后不能再使用 conn 变量
        return;
    }
}
```

---

### 2.2 固定大小的路径段缓冲区
**文件:** `src/antpath.zig`

```zig
pub fn match(self: *const PathRule, path: []const u8) bool {
    var segments_buf: [64][]const u8 = undefined;  // 固定64
    var count: usize = 0;
    // ...
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (count >= segments_buf.len) return false;  // 直接返回 false
        // ...
    }
}
```

**影响:** 超过64段的长路径会静默失败，返回 false（可能拒绝合法请求）

---

### 2.3 RingBuffer 容量检查竞争条件 (中危)
**文件:** `src/spsc_ringbuffer.zig`

```zig
pub fn tryPush(self: *Self, value: T) bool {
    const w = self.write_index.load(.acquire);
    const r = self.read_index.load(.acquire);
    if (w - r >= capacity) return false;  // 读写之间没有锁
    // 在检查和实际写入之间可能有其他线程修改
    const idx = w & (capacity - 1);
    self.buffer[idx] = value;
    self.write_index.store(w + 1, .release);
    return true;
}
```

**说明:** 这是 SPSC ringbuffer 的经典 "ABA" 问题，但在高负载下可能导致超过容量写入

---

### 2.4 Buffer Pool Replenish 队列可能溢出
**文件:** `src/buffer_pool.zig`

```zig
pub fn markReplenish(self: *BufferPool, bid: u16) void {
    if (bid >= self.block_count) return;
    self.replenish_queue.append(self.allocator, bid) catch |err| {
        std.log.err("markReplenish: failed to append...");  // 错误被静默忽略
    };
}
```

**影响:** replenish 队列满时缓冲区无法归还内核，可能导致内存泄漏

---

## 3. 逻辑/功能 Bug

### 3.1 WebSocket Frame 缺少最大 Payload 长度检查
**文件:** `src/ws/frame.zig`

```zig
pub fn parseFrame(data: []u8) !Frame {
    // ...
    if (payload_len == 127) {
        if (data.len < 10) return error.IncompleteFrame;
        payload_len = std.mem.readInt(u64, data[2..10], .big);
        if (payload_len & 0x8000_0000_0000_0000 != 0) return error.InvalidFrame;
        // 缺少最大 payload 长度限制！
        // 攻击者可以声明巨大的 payload_len 但不发送数据
    }
    // ...
}
```

RFC 6455 规定最大 payload 为 2^63-1，但实际应该限制到合理范围（如 16MB）

---

### 3.2 computeAcceptKey 缓冲区处理问题
**文件:** `src/ws/upgrade.zig`

```zig
pub fn computeAcceptKey(key: []const u8, buf: *[29]u8) !void {
    // ...
    _ = std.base64.standard.Encoder.encode(buf[0..28], &hash);
    buf[28] = 0;  // 设置 null terminator，但调用方可能不需要
}
```

**问题:** 手动添加 null terminator 可能是多余的，取决于调用方如何使用

---

### 3.3 中间件路径匹配的潜在问题
**文件:** `src/http/async_server.zig`

当使用精确路径匹配时，没有考虑路径末尾的斜杠：
```zig
if (self.respond_middlewares.precise.get(path)) |list| {
    // 如果注册 /api 但请求 /api/ 则不会匹配
}
```

---

### 3.4 DeferredResponse 可能泄漏内存
**文件:** `src/root.zig`

```zig
pub fn json(self: *const DeferredResponse, status: u16, body: []const u8) void {
    const duped = self.allocator.dupe(u8, body) catch return;
    // 如果 sendDeferredResponse 失败，duped 内存泄漏
    self.server.sendDeferredResponse(self.conn_id, status, .json, duped);
}
```

---

## 4. 并发问题

### 4.1 WorkerPool 自旋锁可能导致 CPU 浪费
**文件:** `src/next/next.zig`

```zig
fn acquire(self: *WorkerPool) void {
    while (@atomicRmw(bool, &self.spinlock, .Xchg, true, .acquire)) {
        std.Thread.yield() catch {};  // 纯自旋 + yield
    }
}
```

**建议:** 考虑使用更高效的同步机制，如 mutex 或 condition variable

---

### 4.2 线程池任务执行后线程引用未正确清理
**文件:** `src/next/next.zig`

```zig
self.submit_threads.append(n.allocator, t) catch {
    t.join();  // 如果添加失败立即 join，但之前的错误已发生
    std.log.err("Next.submit: failed to track thread, joined immediately", .{});
};
```

---

## 5. 错误处理问题

### 5.1 忽略太多错误
多处代码使用 `_ = try ...` 或 `catch {}` 忽略错误：

```zig
// src/http/async_server.zig
_ = try self.ring.accept(...);  // accept 错误被忽略

// src/buffer_pool.zig
self.replenish_queue.append(...) catch |err| {
    std.log.err(...);  // 只打印日志，不恢复
};
```

---

### 5.2 某些关键操作缺少错误处理
```zig
fn submitWrite(self: *Self, conn_id: u64, conn: *Connection) !void {
    // ...
    const sqe = try self.ring.writev(...);
    // writev 失败没有妥善处理
}
```

---

## 6. 代码质量问题

### 6.1 未使用的变量警告
**文件:** `src/ws/server.zig`

```zig
pub fn closeAllActive(self: *WsServer) void {
    var it = self.active.iterator();
    while (it.next()) |entry| {
        self.send_fn(self.ctx, entry.key_ptr.*, .close, "") catch |err| {
            std.debug.print("ws closeAllActive: ...", .{});
        };
    }
}
```

### 6.2 配置值不一致
**文件:** `src/constants.zig`

```zig
pub const MAX_FIXED_FILES = 16384;  // 但 async_server 中初始化为 256
params.sq_entries = 256;
params.cq_entries = 256;
```

---

## 7. 潜在崩溃点

### 7.1 threadlocal 变量未检查
**文件:** `src/next/fiber.zig`

```zig
fn executeUserComplete(caller_ctx: ?*anyopaque, data: []const u8) void {
    const item = pending_user_item.?;  // 如果为 null 会 panic
    item.on_complete(caller_ctx, data);
}
```

---

### 7.2 空指针解引用风险
**文件:** `src/http/async_server.zig`

```zig
const conn = self.connections.getPtr(conn_id) orelse return;
// ...
self.respond(conn, 431, "Request Header Fields Too Large");
// respond 函数内部可能再次访问已删除的连接
```

---

## 8. 总结

| 类别 | 数量 | 严重程度 |
|------|------|----------|
| 安全漏洞 | 4 | 高危: 2, 中危: 2 |
| 内存/资源 | 4 | 高危: 1, 中危: 3 |
| 逻辑 Bug | 4 | 高危: 1, 中危: 3 |
| 并发问题 | 2 | 中危: 2 |
| 错误处理 | 2 | 中危: 2 |
| 代码质量 | 2 | 低危: 2 |
| 潜在崩溃 | 2 | 高危: 2 |

**建议优先级:**
1. 修复安全漏洞 (1.1, 1.3)
2. 修复 use-after-free 风险 (2.1)
3. 添加 Frame payload 长度限制 (3.1)
4. 完善错误处理 (5.1, 5.2)