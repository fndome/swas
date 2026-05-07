# PRE_AMEND_AUDIT.md — 前序修改的自我审计

> 对 PRE_AMEND.md 记录的修改逐项验证：是否把正确的改成了错误的，是否引入回归。
> **第二轮修正**（去原子化）：移除不属于单线程系统的原子操作，消除误导。

---

## 第二轮修正：移除误导性的原子操作

**原则**: sws 的 IO 线程模型是单线程的，所有数据访问都在同一个执行流中。引入 `@atomicStore` / `@cmpxchgStrong` / `@atomicLoad` 不仅不提供保护（因为没有并发），还**主动误导**后续读者和审计者认为存在多线程访问 → 引发假阳性分析。

### 去原子化 1: LargeBufferPool

**原状态**（我的修改）: `acquire()` 用 `@atomicStore(.release)` 设 BUSY，`release()` 用 `@cmpxchgStrong` 两次 CAS + 重试。

**修正后**: 
- `acquire()`: `self.states[idx] = STATE_BUSY` — 普通赋值
- `release()`: `if (self.states[i] == STATE_IDLE) { 双重释放 } else { states[i] = IDLE; freelist 归还 }` — 普通 if 检查
- 删除了 CAS 重试、spurious failure 等不属于单线程模型的逻辑
- 文档明确标注"IO 线程独占，无并发 — 不需要原子操作"

### 去原子化 2: writev_in_flight

**原状态**（我的修改）: 
- `submitWrite`: `@atomicLoad(.acquire)` 检查 + `@atomicStore(.release)` 置位
- `ensureWriteBuf`: `@atomicLoad(.acquire)` 检查
- `onWriteComplete`: 五处 `@atomicStore(.release)` 清零

**修正后**:
- 全部改为普通字段访问: `slot.line4.writev_in_flight != 0` / `= 1` / `= 0`
- IO 线程顺序执行，不存在"另一个线程同时写"的情况
- 内核读取 iovec 是 SQE 提交之后的事 — 提交后 IO 线程不再碰该字段直到 CQE 返回

### 去原子化同时修复的回归

**FIX-3b 回归**: `submitWrite` 的 guard 原来是 `return;`（静默），改为 `return error.WriteInFlight;`。调用方全部用 `catch { closeConn }` 处理，现在能正确捕获。

---

## 逐项验证（第一轮修改）

### 第 1 组：LargeBufferPool IDLE/BUSY 状态机

**验证项**:
- `states` 数组 init 为全 IDLE ✅
- `acquire()` 设置 BUSY 后返回 ✅
- `release()` CAS 逻辑 — 第一轮成功 → 加 freelist ✅; 已是 IDLE → log + skip ✅; CAS 失败 → 重试并检查 ✅; 两次都失败 → log + leak ✅
- `deinit()` 仍遍历 freelist，不受 states 影响 ✅
- `BufferBlockPool` 是泛型函数，同样被 `LargeBufferPool` 以外的地方使用？`grep BufferBlockPool` 只找到 `LargeBufferPool` 一处调用。✅ 无影响

**⚠️ 潜在问题**: `@atomicStore` / `@cmpxchgStrong` 用于单线程场景（IO 线程专用），有轻微性能开销但**不构成正确性回归**。如果未来从多线程调用，现有的 `freelist_top += 1` 非原子操作会成为瓶颈——但这个问题在修改前就存在。

**结论**: ✅ 无回归。

---

### 第 2 组：Fiber 共享栈安全

#### FIX-2a: httpTaskComplete 拆分

**验证项**:
- `httpTaskCleanup` 与 `httpTaskComplete` 逐行对比：唯一差异是缺少 `shared_fiber_active = false` 和多了 `std.debug.assert` ✅
- `httpTaskExecWrapperWithOwnership` 调用 `httpTaskCleanup` ✅
- 共享栈路径仍然调用 `httpTaskComplete` ✅
- `httpTaskCleanup` 在 `httpTaskExec` 返回后才执行，不会与 `ctx.deinit()` 冲突 ✅

**⚠️ 潜在问题**: `httpTaskCleanup` 访问 `t.server.connections.getPtr(t.conn_id)` 时，连接可能已被其他路径关闭（如 TTL 超时）。但这是 `httpTaskComplete` 原有的行为，修改未引入新问题。

**结论**: ✅ 无回归。

#### FIX-2b: WebSocket handler guard

**验证项**:
- `if (self.shared_fiber_active)` guard 在 `ws_frame` 处理之前 ✅
- 共享栈占时走 `wsTaskExecWrapperWithOwnership` → `wsTaskCleanup`（不碰 flag）✅
- 共享栈空闲时仍然走 `wsTaskComplete`（清零 flag）✅
- `wsTaskCleanup` 逐行对比 `wsTaskComplete`：缺少 `shared_fiber_active = false` ✅

**⚠️ 潜在问题**: per-task 路径依赖 `self.next` 存在。如果 `next` 为 null → 回退到同步 handler 调用（不创建 fiber）。此时 WS handler 直接在 IO 线程执行，若 handler 阻塞 → IO 线程卡死。但这是 `self.next == null` 的通用问题，非本次修改引入。

**结论**: ✅ 无回归。

---

### 第 3 组：writev_in_flight 保护链

#### FIX-3a: CacheLine4_6 结构体修改

**验证项**:
- 原 `_pad: [3]u8` → `writev_in_flight: u8 = 0` + `_pad: [2]u8`，总大小不变 ✅
- compime check `@sizeOf(CacheLine4_6) != 128` 仍通过 ✅
- `@offsetOf(StackSlot, "line4") != 192` 仍通过 ✅
- 所有其他字段偏移量不变 ✅

**结论**: ✅ 无回归。

#### FIX-3b: submitWrite guard

**🔴 发现问题**:
```zig
if (@atomicLoad(u8, &slot.line4.writev_in_flight, .acquire) != 0) {
    logErr("submitWrite: writev already in-flight for fd={d}, skipping", .{conn.fd});
    return;  // ← 静默返回，无错误！
}
```

**问题**: 调用方期望 `submitWrite` 要么成功提交 SQE，要么返回 error。但现在它可能**静默返回**——调用方以为写入已提交，实际没有。所有调用者都使用 `catch { closeConn }` 模式：

```zig
self.submitWrite(conn.id, conn) catch {
    self.closeConn(conn.id, conn.fd);
};
```

静默返回 → catch 不触发 → 写入丢失 → 响应永不发送 → 连接挂起。

**风险评估**: 在正常操作中 `writev_in_flight` 始终为 0（在 `onWriteComplete` 中清零后才调用 retry）。此 guard 仅在**已有其他 bug** 时才触发。但一旦触发，静默返回会使问题恶化。

**修复**: 应返回 `error.WriteInFlight` 或类似错误，让调用方的 catch 块执行 closeConn。

---

#### FIX-3c: onWriteComplete 清零

**验证项**:
- `res <= 0` 路径 ✅
- 写完成路径 ✅
- 重试前清零 ✅
- 重试超限路径 ✅
- submitWrite 重试失败 catch 路径 ✅

全部六个清零点覆盖完整。✅

---

#### FIX-3d: ensureWriteBuf guard

**验证项**:
- 在 `freeTieredWriteBuf` 前检查 `writev_in_flight` ✅
- 返回 false → 调用方处理（respondError 或 closeConn）✅
- 逻辑：如果 buffer 正在被内核 DMA 读取，不能释放 ✅

**结论**: ✅ 无回归。

---

### 第 4 组：资源泄漏修复

#### FIX-4a: pending_bid 回收

**验证项**:
- 在 `closeConn` 之前回收 ✅
- 检查 `hw.pending_bid != 0` 避免重复回收 ✅
- 清空 `hw.pending_bid` 和 `hw.pending_len` ✅
- `closeConn` 的回收逻辑只处理 `conn.read_bid`，不会与 pending_bid 冲突 ✅

**结论**: ✅ 无回归。

#### FIX-4b: large_buf_ptr 在 closeConn 中释放

**验证项**:
- 检查 `slot.line3.large_buf_ptr != 0` ✅
- 释放后清零 ✅
- `closeConn` 可被多次调用：第二次 `large_buf_ptr == 0` → 跳过 ✅
- 与 `onBodyChunk` 的释放路径：`closeConn` 先执行释放+清零 → `onBodyChunk` 见 ptr=0 → 跳过。或 `onBodyChunk` 先执行 → `closeConn` 见 ptr=0 → 跳过。两者**不会同时执行**（都在 IO 线程）。✅

**结论**: ✅ 无回归。

#### FIX-4c: flushReplenish 部分失败处理

**验证项**:
- while 循环代替 for + try ✅
- 失败时 `std.mem.copyForwards` 将剩余 bids 移到队首 ✅
- 返回 error 供调用方处理 ✅
- 成功时 `clearRetainingCapacity` 清空 ✅

**⚠️ 潜在问题**: 如果 `provide_buffers` 失败但部分 bids 已成功提供，这些 bids 的**索引已从队首移除**，剩余 bids 移到队首。下次 flush 会对剩余 bids 再次调用 `provide_buffers`。这不会造成重复提供（kernel 会忽略重复的 buffer registration）。✅

**结论**: ✅ 无回归。

---

### 第 5 组：调度公平性 IO_QUANTUM

**验证项**:
- `IO_QUANTUM = 64` 硬编码 ✅
- while 循环受 `count < IO_QUANTUM` 限制 ✅
- 剩余任务留给下一轮 event loop ✅
- `drainNextTasks` 在 event loop fast path 和 slow path 都被调用（两处）— 两处都受限制 ✅

**⚠️ 潜在问题**: 如果某轮有 200 个任务，需要 4 轮 event loop 才能全部处理。每轮之间剩余任务等待 `submit_and_wait` 或新 CQE。对于大量 `Next.go()` 任务堆积的场景，处理延迟增加。但这是设计意图（公平性 > 吞吐）。

**结论**: ✅ 无回归。这是有意的 tradeoff。

---

### 第 6 组：出站模块修复

#### FIX-6a: TinyCache host:port 匹配

**验证项**:
- `PoolEntry.host` dupe 在 `store()`，释放覆盖 `deinit/evictPipe/evictExpired` ✅
- `acquire()` 全字段匹配（host + port + borrowed + ttl）✅
- `store()` OOM 时释放 stream ✅
- `evictPipe()` 释放 host ✅
- `evictExpired()` 释放 host ✅

**结论**: ✅ 无回归。

#### FIX-6b: HttpClient 真实时钟超时

**验证项**:
- `nowMs()` 使用 `CLOCK_MONOTONIC`（Linux 可用）✅
- `deadline_ms` 在循环外计算一次 ✅
- 循环内每次检查 `nowMs() >= deadline_ms` ✅
- 超时后设置 `cancelled = true` 防止 worker path 覆盖 ✅

**结论**: ✅ 正确性改进。

#### FIX-6c/d: DNS submitRecv / registerFds 加 submit

**验证项**:
- `submitRecv`: 仅一个 RECV SQE，无其他 pending SQE → `submit()` 安全 ✅
- `registerFds`: 多个 POLL_ADD SQE → `submit()` 批量提交 ✅
- 不会导致 double-submit（`recv_outstanding` guard 保证只有一个未完成 RECV）✅

**结论**: ✅ 无回归。

---

### 第 7 组：ChunkStream dispatch 边界

**🔴 发现问题**:
```zig
const copy_len = @min(self.offset, self.worker_buf.len);
@memcpy(self.worker_buf[0..copy_len], self.large_buf[0..copy_len]);
const chunk_len = copy_len;
self.offset = 0;  // ← 丢弃了 offset - copy_len 字节！
```

**问题**: 如果 `self.offset > self.worker_buf.len`（在一次大的 `feed()` 后），`@min` 截断到 `worker_buf.len`。但 `self.offset = 0` 会**永久丢弃**超出部分的字节。`self.large_buf` 中的剩余数据会在下次 `feed()` 时被覆盖。

**触发条件**: `feed(data)` 的 data 远超 `threshold`（`worker_buf.len`）。例如 threshold=64KB，data=200KB → offset=264KB → dispatch → copy 64KB → 丢 200KB。

**根源**: `feed()` 不按 threshold 拆分大数据块。这与此修复无关——原始代码在同样条件下会崩溃（buffer overflow）。修复防止了崩溃但引入静默截断。

**修复**: 至少加 `std.log.warn`。更好的修复是在 `feed()` 中将大数据拆分为多个 threshold 块。

---

### 第 8 组：文档/注释修正

**验证项**:
- FIX-8a: 注释改为准确描述 ✅
- FIX-8b: CacheLine2 删除未使用字段，`@sizeOf` comptime check 仍通过 ✅
- FIX-8c: StackSlot 注释改为实际大小 ✅
- FIX-8d~j: README 大小、栈、文档全部与代码一致 ✅

**结论**: ✅ 无回归。纯文档修改。

---

## 审计总结

| Fix | 状态 | 问题 |
|-----|------|------|
| FIX-1 | ✅ | 无回归 |
| FIX-2a | ✅ | 无回归 |
| FIX-2b | ✅ | 无回归 |
| FIX-3a | ✅ | 无回归 |
| **FIX-3b** | **🔴 回归** | **submitWrite 静默返回，应改为返回 error** |
| FIX-3c | ✅ | 无回归 |
| FIX-3d | ✅ | 无回归 |
| FIX-4a | ✅ | 无回归 |
| FIX-4b | ✅ | 无回归 |
| FIX-4c | ✅ | 无回归 |
| FIX-5 | ✅ | 设计意图内 |
| FIX-6a | ✅ | 无回归 |
| FIX-6b | ✅ | 无回归 |
| FIX-6c/d | ✅ | 无回归 |
| **FIX-7** | **🟡 截断** | **防止 crash 但静默丢数据，需加 log** |
| FIX-8 | ✅ | 无回归 |

**引入的回归**:
1. **FIX-3b**: `submitWrite` 的 `writev_in_flight` guard 在 flag 置位时静默返回，应返回 error。当前调用方全部用 `catch { closeConn }` 处理错误，静默返回会导致调用方误以为写入成功。
2. **FIX-7**: `ChunkStream.dispatch` 截断后静默丢数据。作为最小修复应加 `std.log.warn`；完整修复应重写 `feed()` 的分块逻辑。

**确认正确且无副作用的修改**: 其他 15 项。
