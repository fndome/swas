# PENDING_REVIEW

> 审计状态：第一波 PR 已合并（2026-05-09），待第二/三波合并后重新审计。
> 当前基于 commit `949e441` 及之前的第一波改动。

---

## 高优先级

### 1. `event_loop.zig:160` — `waiting_computation` 状态未在 CQE 分发中处理

`dispatchCqes` 枚举了所有 `ConnState` 分支（`.reading`, `.processing`, `.receiving_body`, `.streaming`, `.writing`, `.ws_reading`, `.ws_writing`, `.closing`），但 `ConnState.waiting_computation`（定义于 `src/http/connection.zig:13`）不在其中。任何该状态下的 CQE 都会落入 `else` 分支直接关闭连接。

- 该状态当前全代码库未使用，属死代码。
- 若未来启用（如 Worker Pool 计算完成回调），会触发误杀。

### 2. `src/client/http_client.zig:101` — `makeErrorResponse` 极端回退有 UB

```zig
const body = allocator.dupe(u8, msg) catch allocator.alloc(u8, 0) catch &.{};
```

三级回退：`dupe` → `alloc(0)` → 编译期常量 `&.{}`。`Response.deinit()` 对其调用 `allocator.free()` 是未定义行为。虽仅在极端 OOM 时触发，但仍需修复。

### 3. `src/client/http_client.zig:260-274` — 手动操作 mutex state，同步机制不健全

```zig
ctx.mutex.state.store(.unlocked, .release);   // 绕过 mutex.unlock()
while (!ctx.mutex.tryLock()) ...              // 绕过 mutex.lock()
```

- 直接读写 `state` 绕过了 `std.Io.Mutex` 内置的 futex 等待/唤醒。
- `cond: std.Io.Condition` 字段在 `RequestContext` 中声明但从未使用。
- 当前仅两个线程争用 + spinlock，功能上可工作，但语义错误且未来加线程会暴露问题。

---

## 中优先级

### 4. `src/http/connection_mgr.zig:96-101` — `closeConn` 递归自调用

SQ 满时 `ring.nop` 提交 CLOSE SQE 失败，走回退路径：
```zig
_ = linux.close(fd);
closeConn(self, conn_id, 0);   // 递归，fd=0 触发 connFree
```
终止条件（`fd == 0 or state == .closing → connFree`）正确，但递归调用增加了控制流复杂度。内部大量 `getConn` + `orelse return` 在递归层级间不透明。

### 5. `src/dns/packet.zig:72` — `encodeName` 静默跳过非法标签

```zig
if (label.len > 63 or label.len == 0) continue;
```

对空标签（如 `"example..com"`）或超长标签跳过而非报错，生成畸形 DNS 查询包。

### 6. `src/http/http_fiber.zig:57-107` — 中间件遍历逻辑 3 处重复

`httpTaskExec` 中 global、precise、wildcard 三套中间件遍历的结构完全一致（各约 15 行），仅数据源不同。三处需同步维护，容易漏改。

### 7. `src/outbound/tcp_outbound_ring.zig:188,197` — 每次 I/O 单独 submit

`submitRead` 和 `submitWrite` 内部各自调用 `ring.submit()`，而非在 `tick()` 中统一提交。高频场景每帧额外触发多次 `io_uring_enter` 系统调用。

### 8. `src/http/ws_handler.zig:271` — WS handler fiber 未完成即重新投递 read

```zig
// fiber 执行（可能 yield）
fiber.exec(...);
// 立刻重新 submit read，不等 handler 完成
if (conn.state != .ws_writing) {
    conn.state = .ws_reading;
    self.submitRead(conn_id, conn) catch { ... };
}
```

`shared_fiber_active` 标志保护了共享栈，但 fd 上已允许新帧到达。handler 若未 yield 则无问题；若 yield，新帧通过 `Next.push` 入队。当前正确但耦合度高。

---

## 低优先级 / 代码质量

### 9. 代码重复

| 函数 | 位置 1 | 位置 2 |
|------|--------|--------|
| `readResolvConfNameserver()` | `src/http/async_server.zig:60` | `src/client/ring.zig:123` |
| `parseIpv4()` | `src/http/http_helpers.zig:81` | `src/client/ring.zig:148` |

### 10. 文档与实现不一致

`STRESS_TEST.md:96` 标注 TcpOutboundRing.wbuf 为 4KB，实际代码 `src/outbound/tcp_outbound_ring.zig:179` 为 64KB。另有 `STRESS_TEST.md:80` 提到"DNS resolve 可能阻塞 RingB 线程"，但当前 DNS 已走 io_uring UDP，不阻塞。

### 11. `src/example.zig:111` — 注释 typo

`"[Middleware] Nextuest:"` 应为 `"Request"`。

### 12. `src/ws/frame.zig:107-112` — SIMD 非对齐路径无中等优化回退

指针非 16 字节对齐时跳过整个 SIMD 快路径，逐字节处理。应至少有 8 字节/4 字字节的 SWAR 回退。

### 13. `src/spsc_ringbuffer.zig:64-67` — `RingBuffer.push()` 满时仅 retry 1 次

```zig
pub fn push(...) bool {
    while (!self.tryPush(item)) {
        std.Thread.yield() catch {};
        if (!self.tryPush(item)) return false;  // 一次重试后放弃
    }
    return true;
}
```

yield + 单次重试，失败后任务静默丢失。

### 14. `src/client/http_client.zig:475` — 64KB 栈变量在 fiber 中

```zig
var resp_buf: [65536]u8 = undefined;
```

此变量在 `httpRequestFiber` 的 fiber 栈上分配。配合默认 256KB 共享栈尚可，若 future 使用更小 per-task 栈则有溢出风险。

### 15. `src/shared/tcp_stream.zig:216-220` — 固定文件注册失败被静默忽略

```zig
if (self.rs.ringPtr().register_files_sparse(1)) {
    if (self.rs.ringPtr().register_files_update(0, &[_]linux.fd_t{self.fd})) {
        self.fixed_index = 0;
    } else |_| {}
} else |_| {}
```

两次 fallible 操作均忽略错误，退化到非 fixed-file 路径无日志记录，问题排查困难。

### 16. `src/next/next.zig:218` — `parked.append` 失败时尝试 resume 但未检查返回值

```zig
parked.append(pool.allocator, .{...}) catch {
    @import("fiber.zig").saved_call = call;
    Fiber.resumeContext(ctx);
};
```

`append` 失败时直接 resume fiber 以完成 cleanup，但 `resumeContext` 的完成状态未被检查。如果 resume 后 fiber 再次 yield，会丢失在 parked 列表中。

---

## 后续跟踪

- [ ] 等待第二波 PR 合并，重新审计 `src/http/*`, `src/next/*`, `src/shared/*`
- [ ] 等待第三波 PR 合并，重新审计 `src/client/*`, `src/dns/*`, `src/ws/*`
- [ ] 所有波次完成后，跑 `zig build test` 验证不引入回归
