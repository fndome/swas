# CURRENT.md — 确认存在的漏洞与 Bug

> 经过两轮深度推理 + 源码逐行验证。以下为**已确认真实存在、尚未修复**的问题。
> 已修复的问题和误报不列入此文件。

---

## HIGH

### H-1: ctx.body allocator 绕过 LargeBufferPool [HIGH]
**文件**: `async_server.zig` line 2481 + `context.zig` line 141  
**链路**:  
1. `onBodyChunk` body 收齐 → `processBodyRequest(conn_id, conn, buf)` — buf 来自 `LargeBufferPool.acquire()`  
2. `processBodyRequest` line 940: `t.body_data = @constCast(body_buf)` — 存入 HttpTaskCtx  
3. `httpTaskExec` line 2481: `ctx.body = t.body_data` — 赋值到 Context  
4. `httpTaskExec` line 2486: `defer ctx.deinit()` — 释放 ctx  
5. `ctx.deinit()` line 141: `self.allocator.free(b)` — 用 GeneralPurposeAllocator 释放 LargeBufferPool 内存  

**后果**:  
- LargeBufferPool 的 `blocks[i]` 数组仍指向已被 GPA 释放的内存 → 下次 `acquire()` 返回 use-after-free 指针  
- LargeBufferPool.`deinit()` 时对同一 block 再次 `allocator.free()` → **double-free**  
- 每次 oversized body 请求后 LargeBufferPool 永久损失一个 buffer（容量递减）  

**验证**: line 2481 确认 `body = t.body_data`，line 141 确认 `free(b)`。

---

### H-2: WorkerPool stack_freelist 多线程竞争 [MEDIUM]
> **修正**: 初始评级 HIGH，经实际并发模型分析后降为 MEDIUM。见下方"实际触发条件"。

**文件**: `next/next.zig` — `WorkerPool.releaseStack()` / `acquireStack()`  
**推理**:  
- `stack_pool` 和 `stack_freelist` 在 `WorkerPool.init` 中分配  
- `acquireStack()` 在 `runTask()` 中调用，`releaseStack()` 在 `runTask()` 和 `resumeParked()` 中调用  
- 两者均无互斥锁保护  

**实际触发条件**:
- `initPool4NextSubmit(n)` 中 n > 1 时才存在并发窗口
- n = 0（未初始化）或 n = 1（默认推荐）时，worker 线程只有 0 或 1 个 → 对 `stack_freelist` 的访问是串行的 → **不触发**
- n > 1 时，多个 worker 线程可能同时在 `acquireStack`/`releaseStack` 中读写 `stack_freelist_top` → **触发竞争**

**设计意图**: 系统设计为单 worker（README 推荐值 = 1）。多 worker 场景尚未经过并发审查。

**后果**: 若配置 n > 1 → freelist 损坏 → stack 复用错误 → fiber 在损坏的栈上执行。若配置 n ≤ 1 → 无影响。  

**验证**: `workerLoop` 在调用 `runTask`/`resumeParked` 时不持有 mutex（mutex 仅保护 `pop`/`submit`）。多个 `workerLoop` 实例并发执行。✅ 竞争真实存在但需 n > 1 触发。  

---

### H-3: FS-2 allocator mismatch [HIGH] — 与 H-1 同一问题，已合并到 H-1

---

## MEDIUM

### M-1: connFree 不校验 gen_id 即释放 slot [MEDIUM]
**文件**: `stack_pool_sticker.zig` `connFree()` line 278-284  
**推理**: `connFree` 直接调用 `slotFree(pool, conn.pool_idx)`，不检查 slot 的 `gen_id` 是否与连接创建时一致。如果同一 slot 被重用（新连接复用，gen_id 已变化），`slotFree` 仍会清零新连接的 gen_id 并将 slot 归还 freelist → 新连接丢失。  
**触发**: close 路径被调用两次（罕见但可能：close SQE 的 CQE 和读 CQE 几乎同时到达，且 dispatchCqes 处理顺序不确定）。

---

### M-2: close/read CQE 到达顺序不确定时的状态窗口 [MEDIUM]
**文件**: `async_server.zig` `dispatchCqes()` + `closeConn()`  
**推理**: `closeConn(fd)` 提交 close SQE → 等 CQE → `closeConn(0)` → `connFree`。io_uring 不保证跨 SQE 的 CQE 顺序。如果在 close SQE pending 期间，该连接的读 CQE 先到达：  
1. `dispatchCqes` → state = `.reading` → `onReadComplete` → 可能提交新 read SQE  
2. 新 read SQE 的 fd 已被 close SQE 关闭或即将关闭 → kernel 返回 `-EBADF`  

**当前保护**: line 1684-1691: `.closing` 状态的连接直接进入 close 分支 ✅。但 `closeConn` 在执行 close SQE submission 前才设置 `conn.state = .closing`（line 995）。`submitWrite` 失败的路径在 catch 中直接 `closeConn` — 如果同时有 close CQE pending，可能形成双 close。  
**风险**: 低。`gen_id` + `sticker.getSlotChecked` 提供二次防御。

---

### M-3: DeferredResponse 的 respondZeroCopy 返回 false 时 body 不释放 [MEDIUM]
**文件**: `async_server.zig` `respondZeroCopy()` line ~1866-1894  
**检查结果**: 经源码验证，`respondZeroCopy` 在两个失败分支都释放了 body：  
- `ensureWriteBuf` 失败 → `self.allocator.free(body)` line 1868 ✅  
- `submitWrite` 失败 → `if (conn.write_body) |b| self.allocator.free(b)` line 1890 ✅  
**误报**: 此问题为假阳性。但标注在此以供交叉验证。

---

### M-4: onWriteComplete keep-alive 误判 [MEDIUM]
**文件**: `async_server.zig` — `isKeepAliveConnection()`  
**推理**: `keep_alive` 默认值由 `isKeepAliveConnection` 决定。该函数对 HTTP/1.1 请求默认返回 true（除非显式 `Connection: close`）。如果客户端发送 HTTP/1.1 但不支持 keep-alive（老式 HTTP/1.1 实现），连接会挂起直到 TTL 超时。  
**建议**: `keepAlive` 默认 false，由 `isKeepAliveConnection` 显式开启。

---

### M-5: WS close 帧交换后不主动关闭连接 [MEDIUM]
**文件**: `async_server.zig` `onWsFrame()` `.close` branch  
**推理**: 收到 close 帧 → 发 close 响应 → `conn.state = .ws_writing` → 写完成后 `flushWsWriteQueue` → `conn.state = .ws_reading` + `submitRead`。连接应在 close 帧交换后主动关闭，而非继续等待读取。  
**后果**: 连接挂起直到对端关闭或 TTL 超时。浪费连接槽位。

---

### M-6: WorkerPool 无 IO 线程唤醒机制 [MEDIUM]
**文件**: `next/next.zig` `WorkerPool`  
**推理**: worker 完成计算后通过 `resp.json/text` → `sendDeferredResponse` → `invokeOnIoThread` 投递回 IO 线程。但如果 IO 线程正阻塞在 `submit_and_wait(1)`（无事可做），worker 的 `invoke.push` 成功但 IO 线程不自旋 wake。  
**当前**: IO 线程的 `submit_and_wait(1)` 有 1s 超时（通过 timeout SQE），每 1s 醒来一次处理 invoke。worker 响应延迟可达 1s。  
**建议**: 使用 eventfd 或 `IORING_OP_URING_CMD` 作为 wake-up 机制。

---

### M-7: DNS resolver 的 dnsResume 不检查 gen_id [MEDIUM]
**文件**: `dns/resolver.zig` line 196, 222, 232  
**推理**: `Fiber.dnsResume()` 直接恢复 fiber，不校验目标连接的 slot 是否仍有效。如果原始连接在 DNS 查询期间被关闭且 slot 被重用，resume 的 fiber 会在新连接上继续执行 → **fiber 上下文混乱**。  
**当前缓解**: DNS 结果通过 `self.results` hashmap 传递，不直接写入 slot 字段，降低影响面。

---

### M-8: dns/packet.zig skipName 压缩指针循环 [MEDIUM]
**文件**: `dns/packet.zig` `skipName()`  
**推理**: 如果 DNS 响应包含恶意压缩指针循环（`0xC0 0x00` 指向自身），`skipName` 在 `while` 循环中反复跳转同一位置。有 `off < packet.len` 限制，但压缩指针每次跳 2 字节，512 字节的包最多循环 256 次 → 轻微 DoS。  
**建议**: 加 jump count 上限（如 10）。

---

### M-9: StackSlot 哨兵仅 alloc 时检查 [MEDIUM]
**文件**: `stack_pool_sticker.zig` `slotAlloc()` line 57  
**推理**: `std.debug.assert(slot.line5.sentinel == 0x53574153)` 仅在分配时检查。如果上一个使用者发生缓冲区溢出覆盖了哨兵，只有在下次分配同一 slot 时才能发现。Debug 模式下滞后严重，ReleaseSafe 下 assert 完全移除。  
**建议**: TTL 扫描时也对活跃 slot 做哨兵校验。

---

## LOW

### L-1: HttpClient 超时使用真实时钟但仍 busy-wait [LOW]
**文件**: `client/http_client.zig` `request()`  
**推理**: 已修复超时用 `nowMs()` deadline（✅），但 `while (!ctx.done)` 循环仍然是纯 busy-wait（yield + lock），会在调用者线程持续消耗 CPU。`std.Thread.yield()` 在无其他就绪线程时立即返回 → 100% CPU 空转。  
**建议**: 改用 `std.Thread.Condition` 或 futex wait。

---

### L-2: HttpClient 每次请求重复 DNS resolve [LOW]
**文件**: `client/http_client.zig` `httpRequestFiber()` line 328  
**推理**: `ring_b.dns.resolve(parsed.host)` 每次都调，即使 TinyCache 已有同 host 的 TCP 连接。DNS 结果应缓存在连接池中随连接一起复用。

---

### L-3: submitWrite 无 LINK_TIMEOUT [LOW]
**文件**: `async_server.zig` `submitWrite()`  
**推理**: writev SQE 无 `IOSQE_IO_LINK` + `IORING_OP_LINK_TIMEOUT`。如果对端 TCP window = 0，write SQE 永不完成 → 连接永久挂起。当前仅依赖 `maxWriteRetries` 做应用层重试计数，但每次重试都需 CQE 返回（short write）。若 CQE 因 TCP stalled 永不返回 → 无解。  
**建议**: 加 `LINK_TIMEOUT`（使用 `write_timeout_ms` 配置）。

---

### L-4: BufferPool.replenish 队列溢出标记丢失 [LOW]
**文件**: `buffer_pool.zig` `markReplenish()`  
**推理**: `markReplenish` 使用 `replenish_queue.append(self.allocator, bid) catch |err| { ... }` — 如果 append 失败（OOM），错误被 log 但 bid **不被处理**。io_uring 提供的 buffer 永久丢失。  
**建议**: 失败时至少重试或在下次 `flushReplenish` 中重新入队。

---

### L-5: Fiber.currentYield() 非 fiber 上下文静默返回 [LOW]
**文件**: `next/fiber.zig` `currentYield()` line 71  
**推理**: `const ctx = current_context orelse return` — 如果非 fiber 上下文意外调用 `currentYield()`（如直接在 IO 线程 handler 中调用 Pipe.read()），函数静默返回，调用者以为 yield 成功 → 逻辑错误。  
**建议**: log 错误或 @panic。

---

### L-6: Pipe.feed() pushResume 传 slot_idx=0 [LOW]
**文件**: `next/pipe.zig` `feed()` line 56, 62  
**推理**: `Fiber.pushResume(0, 0, data)` — slot_idx 和 gen_id 都传 0。`drainPendingResumes` 中 `if (entry.slot_idx != 0 and entry.gen_id != 0)` 跳过校验 → 无 ghost fiber 防御。  
**建议**: 传有效 slot_idx。

---

### L-7: Pipe.feed() 缓冲区满时无错误信息 [LOW]
**文件**: `next/pipe.zig` `feed()` line 53-58  
**推理**: 超过 `max_read` 时 pushResume 唤醒 fiber，数据全丢。`Reader.read()` 醒来后 `read_buf.items.len == 0` → 返回 `error.Closed`。调用者误以为连接关闭，实际是 buffer full。  
**建议**: 返回专用错误 `error.BufferFull`。

---

### L-8: RingSharedClient.connect 双重 submit 孤儿 LINK_TIMEOUT [LOW]
**文件**: `shared/tcp_stream.zig` `submitPollOut()`  
**推理**: 先 `ring.submit()` 提交 CONNECT SQE（line 141），再创建 LINK_TIMEOUT SQE 并 `ring.submit()`（line 152）。如果第一次 submit 后 CQE 立即到达（如连接被拒绝），第二次 LINK_TIMEOUT SQE 成为孤儿 — kernel 超时后产生 CQE 但 `IORegistry.dispatch` 找不到对应的 user_data → 静默丢弃。  
**建议**: 将 CONNECT + LINK_TIMEOUT 放在同一 batch 中一次 submit。

---

### L-9: RingB deinit 不清理 pending DNS [LOW]
**文件**: `client/ring.zig` `deinit()` line 72-78  
**推理**: `self.dns.deinit()` 不遍历 `self.dns.pending` hashmap 通知等待者。有进行中 DNS 查询时，fiber 已 yield → deinit 后其 slot 被释放 → resume 时访问已释放内存。  
**建议**: deinit 前遍历 pending，对每个 entry 设置空结果并 resume。

---

### L-10: AsyncServer.deinit 不释放 active large_buf [LOW]
**文件**: `async_server.zig` `deinit()` line 380-391  
**推理**: deinit 遍历连接释放 write_body/ws_token/response_buf，但不释放 `large_pool` 中被占用的 buffer。有连接在 `.receiving_body` 状态时 `large_buf_ptr` ≠ 0 → 泄漏。虽然后续 `large_pool.deinit` 会释放所有 blocks，但 blocks 数组中的 `freelist` 和 `states` 不一致会导致日志污染。  
**建议**: deinit 遍历时检查并释放 `large_buf_ptr`。

---

### L-11: Content-Length 负数静默忽略 [LOW]
**文件**: `http/context.zig` `getContentLength()` line 118  
**推理**: `std.fmt.parseInt(usize, val, 10) catch 0` — Content-Length: -1 → parseInt 失败 → 返回 0。POST 请求的 body 被忽略，应返回 400 Bad Request。

---

### L-12: MAX_PATH_LENGTH=2048 可能过小 [LOW]
**文件**: `http/http_helpers.zig` line 19  
**推理**: HTTP 规范建议 URI ≤ 8000，2048 对部分 API 过小。

---

### L-13: freelist_top 非原子 [LOW]
**文件**: `shared/large_buffer_pool.zig` `release()`  
**推理**: 文档标注 IO 线程专用但 `release` 使用 CAS（暗示并发）。如果 future 从 worker 线程调 `release`，`freelist_top += 1` 会竞争。  

---

### L-14: RingBuffer buffer = undefined [LOW]
**文件**: `spsc_ringbuffer.zig` `init()`  
**推理**: buffer 在 init 时设为 undefined。虽无运行时风险，但不合安全实践。

---

### L-15: encodeName 静默跳过超长 DNS label [LOW]
**文件**: `dns/packet.zig` `encodeName()` line 72  
**推理**: `if (label.len > 63) continue` — 应报错。

---

### L-16: 架构限制 — 单 shared_fiber_stack 无并发 handler [LOW]
**文件**: `async_server.zig` — 整体设计  
**推理**: 所有 handler 共享一个 fiber 栈（256KB），同一时刻只能有一个 handler 执行。handler 做同步重活会阻塞整个事件循环。**这是设计选择，非 bug，但需文档明确**。

---

## 汇总

> **并发模型校准**: 经系统原生时序分析，sws 的设计是 IO 线程独占所有数据 + Worker 线程通过移交点通信。
> IO/Worker 之间不存在数据共享，仅 WorkerPool 内部（n > 1 时）有 worker 间竞争。

| 严重度 | 数量 | 编号 |
|--------|------|------|
| HIGH | 1 | H-1 (allocator bypass — 任何 oversized body 请求触发) |
| MEDIUM | 8 | M-1~M-9, H-2(降级) |
| LOW | 16 | L-1~L-16 |
| **待修复总计** | **25** | |
