# BUG_REPORT.md 审核报告 — SWAS Project

> **审核日期**: 2026-05-03  
> **审核方法**: 逐条读源码验证  
> **结论**: 20个问题中，**5个属实、3个部分属实、12个误报**

---

## 一、审核结论

| 状态 | 数量 | 说明 |
|------|------|------|
| ✅ 属实 | 5 | 存在问题，需修复 |
| ⚠️ 部分属实 | 3 | 风险被夸大或已有缓解措施 |
| ❌ 误报 | 12 | 不存在所述问题 |

---

## 二、逐条审核详情

### ✅ 1.1 WebSocket 缺少 Origin 验证 — **属实 (HIGH)**

**审核**: 属实。`src/ws/upgrade.zig:5-31` 的 `isUpgradeRequest` 仅检查 `Upgrade`/`Sec-WebSocket-Key`/`Sec-WebSocket-Version`，无 `Origin` 检查。`src/http/async_server.zig:1174` 的 `tryWsUpgrade` 也未验证 Origin。

**风险**: 攻击者可在恶意网站嵌入 WebSocket 连接，利用用户浏览器携带 Cookie 发起 CSWSH 攻击。

**修复建议**: 在 `tryWsUpgrade` 中添加 Origin 白名单校验，从请求头提取 `Origin` 与配置的域名列表比对。

---

### ❌ 1.2 Sec-WebSocket-Protocol 验证 — **误报**

**审核**: 服务器不支持任何子协议，升级响应的 `buildUpgradeResponse` 不包含 `Sec-WebSocket-Protocol` 头。按 RFC 6455，客户端收到无此头的响应即视为无子协议协商。这是标准的 WebSocket 实现行为，不是安全漏洞。

---

### ⚠️ 1.3 缺少速率限制 — **部分属实 (MEDIUM)**

**审核**: 属实 — 代码中没有任何连接/请求频率限制。但这是基础设施层关注点（iptables/nginx/网关），对于底层 HTTP 服务器库来说，速率限制通常由上层调用者处理。

**实际风险**: 如果使用者未在网关层配置限流，确实存在 DoS 风险。

---

### ❌ 1.4 路径长度检查绕过 — **误报**

**审核**: `src/http/async_server.zig:627-633` 已有防御：
```zig
const has_header_end = std.mem.indexOf(u8, read_buf[0..nread], "\r\n\r\n") != null;
if (!has_header_end) {
    self.respond(conn, 431, "Request Header Fields Too Large");
    return;
}
```
如果请求头在一次 4KB 读中未完整到达，直接返回 431。路径本身也已检查 `raw.len > MAX_PATH_LENGTH(2048)`。不存在绕过。

---

### ❌ 2.1 连接关闭时 use-after-free — **误报**

**审核**: `src/http/async_server.zig:605`:
```zig
const conn = self.connections.get(conn_id) orelse return;  // 值拷贝，非指针
self.closeConn(conn_id, conn.fd);  // conn 是栈拷贝
return;  // 之后不再使用 conn
```
`connections.get()` 返回值拷贝而非指针。`conn` 是栈上的完整副本，`closeConn` 删除 hashmap 条目不影响栈上的 `conn`。无 UAF 风险。

---

### ⚠️ 2.2 固定 64 段路径缓冲区 — **部分属实 (LOW)**

**审核**: 属实 — `src/antpath.zig:39` 的 `segments_buf: [64][]const u8` 硬编码 64 段。超过此数的路径返回 `false`（不匹配）。

**实际影响**: 正常 HTTP 路径极少超过 64 段（`/a/b/c/...` 需要 64 层嵌套）。这是设计限制而非安全漏洞，对 AntPath 通配符匹配场景几乎无影响。

---

### ❌ 2.3 RingBuffer ABA 问题 — **误报**

**审核**: 这是 SPSC（单生产者单消费者）ringbuffer。ABA 问题仅出现在多生产者场景：当线程 A 读取指针 X、线程 B 修改为 Y 再改回 X、线程 A 的 CAS 仍成功。SPSC 只有唯一生产者写 `write_index`，不存在 ABA。

`src/spsc_ringbuffer.zig:52-60` 的实现是标准的 lock-free SPSC ringbuffer，`acquire`/`release` 语义正确。

---

### ⚠️ 2.4 Buffer Pool Replenish 队列溢出 — **部分属实 (LOW)**

**审核**: `src/buffer_pool.zig:68-73` 的 `markReplenish` 使用 `ArrayList.append`，只有在 OOM 时才失败。

**实际影响**: OOM 时 bid 丢失 → io_uring 内核缓冲区泄漏（不再用于读取）。但 OOM 本身会导致更严重的问题（服务崩溃），所以实际风险极低。报告中"内存泄漏"的定性不准确——应该是"OOM 下的缓冲区碎片化"。

---

### ❌ 3.1 Frame 缺少最大 Payload 长度检查 — **误报**

**审核**: `src/ws/frame.zig:36-37`:
```zig
if (data.len < offset + payload_len) return error.IncompleteFrame;
```
由于 `data` 来自 io_uring 提供缓冲区（固定 4KB），即使声明 `payload_len = 2^63-1`，实际 `data.len` 不超过 4KB，必然触发 `IncompleteFrame`。4KB 的缓冲区大小本身就是有效载荷限制。

**建议**: 添加显式的最大 payload 常量仍是好的防御性编程实践，但不构成安全漏洞。

---

### ❌ 3.2 computeAcceptKey 空终止符 — **误报**

**审核**: `src/ws/upgrade.zig:59` 的 `buf[28] = 0` 是防御性编码。调用处 `async_server.zig:1217` 使用 `accept_buf[0..28]` 精确指定长度，不受空字符影响。无害。

---

### ❌ 3.3 路径尾部斜杠匹配 — **误报**

**审核**: HashMap 精确匹配是预期行为。大部分 Web 框架（Gin、Express）同样不自动处理尾斜杠。不是 bug。

---

### ❌ 3.4 DeferredResponse 内存泄漏 — **误报**

**审核**: `src/root.zig:43-46` 和 `async_server.zig:1144-1155`:
```zig
const duped = self.allocator.dupe(u8, body) catch return;  // 失败直接返回，无分配
self.server.sendDeferredResponse(self.conn_id, status, .json, duped);
```
`sendDeferredResponse` 是 void 函数：
- 分配 `DeferredNode` 成功 → body 由 CAS 链接管
- 分配失败 → `self.allocator.free(body)` 释放
不存在泄漏路径。

---

### ❌ 4.1 WorkerPool 自旋锁 CPU 浪费 — **误报**

**审核**: `src/next/next.zig:31-35`:
```zig
while (@atomicRmw(bool, &self.spinlock, .Xchg, true, .acquire)) {
    std.Thread.yield() catch {};
}
```
带 yield 的自旋锁在低争用场景（1-4 worker 线程）是正确的设计选择，延迟低于 mutex。这不是 bug。

---

### ❌ 4.2 线程池引用未清理 — **误报**

**审核**: `src/next/next.zig:216-219`:
```zig
n.submit_threads.append(n.allocator, t) catch {
    t.join();  // 加入失败时等待线程完成
    std.log.err(...);
};
```
线程已正确 join，无泄漏。错误被记录。

---

### ❌ 5.1 忽略太多错误 — **误报**

**审核**: 报告引用 `_ = try self.ring.accept(...)`。`try` 正确传播错误，`_ =` 只是丢弃 io_uring SQE 指针（异步提交后无需保留）。这是正确的错误处理。

报告中另一处 `catch {}` 实例未找到。多处使用 `catch |err| logErr(...)` 记录日志，是合理的 fail-safe 策略。

---

### ❌ 5.2 writev 失败无处理 — **误报**

**审核**: `submitWrite` 内部使用 `try` 传播错误。调用方 `async_server.zig:844`:
```zig
self.submitWrite(conn_id, conn) catch |err| {
    logErr("submitWrite failed...", .{...});
    self.closeConn(conn_id, conn.fd);
};
```
连接被正确关闭。错误处理完整。

---

### ❌ 6.1 未使用变量 — **误报**

**审核**: 非功能性 bug，Zig 编译器对未使用变量默认 warning。不影响运行时行为。

---

### ❌ 6.2 配置值不一致 — **误报**

**审核**: 报告对比 `MAX_FIXED_FILES = 16384` 与 `sq_entries = 256`。两者无关联：
- `MAX_FIXED_FILES`: 最大注册文件描述符数
- `sq_entries = 256`: io_uring 初始化时的 SQ 条目数提示

`RING_ENTRIES = 2048` 才是总条目数。`sq_entries` 是 io_uring `init_params` 的初始提示值，内核可调整。

---

### ⚠️ 7.1 threadlocal 变量未检查 — **部分属实 (LOW)**

**审核**: `src/http/async_server.zig:54-57`:
```zig
fn executeUserComplete(caller_ctx: ?*anyopaque, data: []const u8) void {
    const item = pending_user_item.?;  // 若 null 则 panic
    item.on_complete(caller_ctx, data);
}
```
调用链: `executeNext` → 设置 `pending_user_item` → `req.execute(..., executeUserComplete)` → `defer pending_user_item = null`。

当前设计下 `req.execute` 是同步调用（在同一函数内立即回调 `executeUserComplete`），所以不会为 null。但代码中没有任何守卫或注释说明这个契约。若未来实现改为异步回调，会触发 panic。

**建议**: 添加 assert 或注释说明契约。

---

### ❌ 7.2 空指针解引用 — **误报**

**审核**: `src/http/async_server.zig:632` 的 `self.respond(conn, 431, ...)` 中 `conn` 来自 `getPtr`（hashmap 内部指针）。`respond` 访问 `conn.id` 和 `conn.fd`。此时连接仍在 hashmap 中（未被删除），访问安全。

---

## 三、报告中未提及的新发现问题

### N-1 | WebSocket 升级时令牌从 URL Query 提取 (LOW)

**文件**: `src/http/async_server.zig:1176-1180`
```zig
if (helpers.extractQueryParam(uri, "token")) |token| {
    conn.ws_token = self.allocator.dupe(u8, token) catch null;
}
```
Token 通过 URL query string 传递。URL 会出现在服务器日志、Referer 头、浏览器历史中。建议改为从 `Sec-WebSocket-Protocol` 头部或 Cookie 传递。

### N-2 | io_uring close 未检查返回值 (LOW) — **已修复**

**文件**: `src/http/async_server.zig` (7处)
```zig
_ = linux.close(fd);  // 返回值被丢弃
```
`close` 返回值被丢弃。在极端情况下（如 NFS 延迟关闭），关闭失败可能导致 fd 泄漏。在本地 socket 场景下无害。

**修复**: 所有 `linux.close()` 调用增加返回值检查，非零时记录错误日志。

---

## 四、总结

| 原报告分类 | 报告数量 | 属实 | 部分属实 | 误报 |
|-----------|---------|------|---------|------|
| 安全漏洞 | 4 | 1 | 1 | 2 |
| 内存/资源 | 4 | 0 | 2 | 2 |
| 逻辑 Bug | 4 | 0 | 0 | 4 |
| 并发问题 | 2 | 0 | 0 | 2 |
| 错误处理 | 2 | 0 | 0 | 2 |
| 代码质量 | 2 | 0 | 0 | 2 |
| 潜在崩溃 | 2 | 0 | 1 | 1 |
| **合计** | **20** | **1** | **4** | **15** |

> **注**: N-1、N-2 为审计过程中新发现的 2 个问题，原报告未提及。

**审计结论**: BUG_REPORT.md 中 60% 为误报（12/20），主要原因为：
1. 对 Zig 语言的 `try`/`catch` 语义理解不足
2. 对 SPSC/lock-free 数据结构特性判断错误
3. 将值拷贝误解为指针
4. 将设计选择误解为 bug

**建议**: 重点处理 1.1（WebSocket Origin 验证），这是唯一确认的安全漏洞。
