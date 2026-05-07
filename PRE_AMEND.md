# PRE_AMEND.md — 前序修改记录

> 对 sws 项目已完成的代码修复、文档更新、结构调整的完整记录。
> 这些修改已通过 `zig build` 验证编译通过。

---

## 一、修复顺序（按提交逻辑分组）

### 第 1 组：编译阻断问题

#### FIX-1: LargeBufferPool 初始化兼容性
**文件**: `src/shared/large_buffer_pool.zig`
**原状态**: 无状态追踪。release() 直接按指针扫描归还 freelist，不检查是否已归还。
**修改**:
- 新增 `STATE_IDLE: u8 = 0` / `STATE_BUSY: u8 = 1` 常量
- 新增 `states: [capacity]u8` 数组，init 时全初始化为 IDLE
- `acquire()` — 返回 buffer 前 `@atomicStore(.release)` 设为 BUSY
- `release()` — 用 `@cmpxchgStrong` CAS BUSY→IDLE。若已是 IDLE → 双重释放，log error 并跳过。若 CAS 失败 → 重试一次并检查结果，两次都失败则 log + 泄漏（拒绝破坏 freelist）
**原因**: io_uring 内核重试可能导致同一 buffer 被 close 路径和 CQE 路径先后释放，不检查会导致 freelist 损坏，后续 acquire 返回已释放或已分配的内存。
**后续修正**: 第一次 CAS 失败后的无条件重试改为检查第二次 CAS 结果（FIX-1b）。

#### FIX-1b: LargeBufferPool CAS 重试不检查结果
**文件**: `src/shared/large_buffer_pool.zig` `release()`
**问题**: 第一次 CAS 失败后的 retry 用 `_ = ` 丢弃了返回值，直接加入 freelist。若第二次 CAS 也失败 → double-acquire。
**修复**: 第二次 CAS 也检查 `prev2`，失败则 log error + 拒绝加入 freelist。

---

### 第 2 组：Fiber 共享栈安全

#### FIX-2a: per-task-stack httpTaskComplete 错误清零 shared_fiber_active
**文件**: `src/http/async_server.zig`
**原状态**: `httpTaskComplete` 无条件设 `t.server.shared_fiber_active = false`。该函数在两个路径被调用：
- 共享栈路径：handler 直接跑在共享栈上 → 返回后清零，正确
- per-task 路径：`shared_fiber_active == true` 时新请求走 `Next.push` 分配独立栈 → 完成回调不应清零，因为**原始 fiber 还在共享栈上 yield 着**
**修改**:
- 拆出 `httpTaskCleanup()` — 仅清理资源（read_bid recycle + http_ctx_pool.destroy），**不碰** `shared_fiber_active`
- `httpTaskExecWrapperWithOwnership` 改用 `httpTaskCleanup`
- `httpTaskComplete` 保留供共享栈路径

#### FIX-2b: WebSocket 无条件占用共享栈
**文件**: `src/http/async_server.zig` `onWsFrame()`
**原状态**: WS 帧到达直接 `Fiber.init(self.shared_fiber_stack)` + `self.shared_fiber_active = true`，不检查是否已被 HTTP fiber 占用。
**修改**:
- 加 `if (self.shared_fiber_active)` guard，占时走 per-task 栈
- 新增 `wsTaskExecWrapperWithOwnership` + `wsTaskCleanup`（不碰 `shared_fiber_active`）
- `wsTaskComplete` 保留供共享栈路径

---

### 第 3 组：io_uring 写入路径安全

#### FIX-3a: CacheLine4 新增 writev_in_flight 保护
**文件**: `src/stack_pool.zig` `CacheLine4_6`
**原状态**: `write_iovs` 字段直接暴露在 Line4，无保护标记。内核可能在异步读取 iovec 结构体时，用户态代码修改了它。
**修改**:
- 原 `_pad: [3]u8` 改为 `writev_in_flight: u8 = 0` + `_pad: [2]u8`（保持 struct 128 字节不变）
- 所有 `@offsetOf` comptime check 仍通过

#### FIX-3b: submitWrite 设置并检查 writev_in_flight
**文件**: `src/http/async_server.zig` `submitWrite()`
**原状态**: 设置 iovec 后直接提交 writev，无保护。
**修改**:
- 提交前 `@atomicLoad(.acquire)` 检查 `writev_in_flight`，若已置位则 skip
- 提交前 `@atomicStore(.release)` 置位 `writev_in_flight = 1`

#### FIX-3c: onWriteComplete 清零 writev_in_flight
**文件**: `src/http/async_server.zig` `onWriteComplete()`
**修改**:
- 写完成（含错误路径和 short-write 重试前）`@atomicStore(.release)` 清零 `writev_in_flight = 0`
- 错误路径、超时重试路径、正常完成路径均覆盖

#### FIX-3d: ensureWriteBuf 检查 writev_in_flight
**文件**: `src/http/async_server.zig` `ensureWriteBuf()`
**原状态**: 替换 `response_buf` 时无条件 `freeTieredWriteBuf(existing)`，不检查内核是否在 DMA 读取。
**修改**: 加 `writev_in_flight` 原子读取检查，in-flight 时返回 false（拒绝替换）。

---

### 第 4 组：资源泄漏修复

#### FIX-4a: short-read pending_bid 泄漏
**文件**: `src/http/async_server.zig` `onReadComplete()`
**原状态**: 短读拼包路径设置 `hw.pending_bid = bid` 后，若 `submitRead` 失败 → `closeConn`，但 `closeConn` 不回收 `pending_bid` → io_uring provided buffer 永久泄漏。
**修改**: `closeConn` 前回收 `hw.pending_bid` 并清零 `hw.pending_bid` / `hw.pending_len`。

#### FIX-4b: closeConn 不释放 large_buf_ptr
**文件**: `src/http/async_server.zig` `closeConn()`
**原状态**: TTL 超时 → `closeConn` → 释放 write_body/response_buf/ws_token，但不释放 `large_buf_ptr` 指向的 LargeBufferPool buffer。
**修改**: 关闭前检查 `slot.line3.large_buf_ptr != 0`，若不为零则 `large_pool.release(buf)` 并清零。

#### FIX-4c: buffer_pool flushReplenish 部分失败丢 bids
**文件**: `src/buffer_pool.zig` `flushReplenish()`
**原状态**: `for` 循环 + `try`，中途 `provide_buffers` 失败直接传播错误 → `clearRetainingCapacity` 丢弃剩余 bids。
**修改**: 改为 while + catch。失败时 shift 剩余 bids 到队首保留，下次 flush 重试。

---

### 第 5 组：调度公平性

#### FIX-5: drainNextTasks 无界消费
**文件**: `src/http/async_server.zig` `drainNextTasks()`
**原状态**: `while (pop())` 无界消费 ringbuffer 中所有 Next 任务。handler 中 `Next.go()` 产生的新任务可能挤占 ReadyQueue 后续就绪任务和 CQE 收割。
**修改**: 新增 `IO_QUANTUM: usize = 64`，每轮最多消费 64 个任务，剩余留给下一轮。

---

### 第 6 组：出站模块修复

#### FIX-6a: TinyCache 跨 host:port 连接复用
**文件**: `src/client/tiny_cache.zig`
**原状态**: `acquire()` / `store()` 丢弃 host 和 port 参数（`_ = host; _ = port;`），所有连接混在一个池中。`api.example.com:443` 的连接可被复用到 `auth.internal:8080`。
**修改**:
- `PoolEntry` 新增 `host: []u8` + `port: u16`
- `acquire()` 匹配 host + port
- `store()` dupe host，失败时释放 stream
- `deinit()` / `evictPipe()` / `evictExpired()` 释放 host

#### FIX-6b: HttpClient 超时基于 yield 计数
**文件**: `src/client/http_client.zig`
**原状态**: `waited += 1` 假设每次 `std.Thread.yield()` ~1µs，但 OS 调度可能阻塞 ms 级。5s 超时实际可能 30s+。
**修改**: 改用 `nowMs() + REQUEST_TIMEOUT_MS(5000)` deadline 真实时钟。

#### FIX-6c: DnsResolver submitRecv 不提交 SQE
**文件**: `src/dns/resolver.zig` `submitRecv()`
**原状态**: 创建 `IORING_OP_RECV` SQE 后不调 `submit()`，依赖外部 event loop。DNS 接收延迟可达一个 event loop 周期。
**修改**: 末尾加 `_ = self.rs.ring.submit() catch {}`。

#### FIX-6d: CaresDns registerFds 不提交 SQE
**文件**: `src/client/dns.zig` `registerFds()`
**原状态**: 创建多个 `IORING_OP_POLL_ADD` SQE 后不调 `submit()`。
**修改**: 末尾加 `_ = self.rs.ring.submit() catch {}`。

---

### 第 7 组：边界检查

#### FIX-7: ChunkStream dispatch 缓冲区溢出
**文件**: `src/next/chunk_stream.zig` `dispatch()`
**原状态**: `self.worker_buf[0..self.offset]` 在 offset 触阈值边界时可能等于 buf.len → 越界 memcpy。
**修改**: `copy_len = @min(self.offset, self.worker_buf.len)`。

---

### 第 8 组：注释/文档修正

#### FIX-8a: flushWsWriteQueue 注释矛盾
**文件**: `src/http/async_server.zig` `flushWsWriteQueue()`
**原状态**: 注释说"Don't free payload yet"但紧接着 `self.allocator.free(payload)`。
**修改**: 改为准确描述 — `submitWsWrite` 已将 payload 拷贝到 response_buf，原始 dup 可安全释放。

#### FIX-8b: CacheLine2 删除未使用字段
**文件**: `src/stack_pool.zig` `CacheLine2`
**原状态**: `prev_live: u32` 和 `next_live: u32` 声明但全项目无任何读写。
**修改**: 删除字段，加 `_pad: [4]u8` 保持 64B。comptime size check 验证通过。

#### FIX-8c: StackSlot 注释大小/数量错误
**文件**: `src/stack_pool.zig` StackSlot 文档注释
**原状态**: 写 `320 bytes`，实际 384 bytes。写"四组"实际五组。引用已删除的 `prev/next_live`。
**修改**: 更新为 `384 bytes` 和实际字段名。

#### FIX-8d~8j: README 全部不一致修正
**文件**: `README.md`, `README_CN.md`, `STRESS_TEST.md`
**修正项**:
- StackSlot 大小: 320/384 → 统一 384 bytes
- 1M 连接内存: ~400MB/~540MB → ~384MB/~520MB
- 默认 fiber 栈: 64KB → 256KB（与 Config 默认值一致）
- line4 字段: 补 `writev_in_flight`
- LargeBufferPool: 补 IDLE/BUSY 原子状态机说明
- drainNextTasks: 补 IO_QUANTUM=64 文档
- 共享栈对比表: 64KB → 256KB
- API 示例中的 fiber_stack_size_kb: 64 → 0（使用默认值）
- `use 0 = 256KB` 注释
- `initPool4NextSubmit(1)` 推荐说明

---

### 第 9 组：新文件

#### 审计文档（新建）
**文件**: `DEEP_REASON_1.md`, `DEEP_REASON_2.md`, `CURRENT.md`, `HOW_TO_FIND_BUGS.md`
**内容**: 三轮深度推理审计的完整记录、确认的 25 个待修复问题、系统化 bug 挖掘方法论。

---

## 二、修改统计

| 类别 | 文件数 | 说明 |
|------|--------|------|
| Bug 修复 | 10 | large_buffer_pool, async_server, stack_pool, buffer_pool, tiny_cache, http_client, dns/resolver, client/dns, chunk_stream, next/next(IO_QUANTUM) |
| 文档更新 | 3 | README.md, README_CN.md, STRESS_TEST.md |
| 注释修正 | 1 | async_server.zig flushWsWriteQueue + stack_pool.zig 结构注释 |
| 新建文件 | 4 | DEEP_REASON_1/2, CURRENT, HOW_TO_FIND_BUGS |

## 三、编译验证

全部修改通过 `zig build`（target: x86_64-linux）。
