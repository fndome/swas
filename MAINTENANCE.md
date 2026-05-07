# MAINTENANCE.md — 维护指导

> 基于三轮深度审计 + 15 项修复的实战经验。简洁有效。

---

## 第一原则：理解并发模型

**sws 是单线程系统。** 这是所有判断的基石。

```
IO 线程拥有一切：StackPool、Connections、BufferPool、LargeBufferPool、Ring
Worker 线程只拥有自己的栈。

数据流向：
  IO ──[submit]──→ mutex 队列 ──→ Worker 消费
  Worker ──[invoke]──→ CAS 链表 ──→ IO drainTick
```

**不存在 IO 线程和 Worker 线程共享的可变数据。** 两者通过两个单向移交点通信。

---

## 改代码前必须回答的三个问题

1. **这个数据在哪个执行流中？** — IO 线程？Worker 线程？还是两者？
2. **如果只在 IO 线程，绝对不要加原子操作或锁。** 这会误导后续所有人。
3. **如果跨线程，通过哪个移交点？** — submit（mutex 队列）还是 invoke（CAS 链表）？如果是别的路径，那是 bug。

---

## 常见错误

| 错误 | 为什么 |
|------|--------|
| 给 IO 线程数据加 `@atomicStore` | 无并发，原子操作是噪音 + 误导 |
| 给 StackSlot 加锁 | IO 线程独占 |
| 担心 `shared_fiber_active` 需要原子 | 仅 IO 线程读写（per-task wrapper 不碰） |
| 把通用多线程经验套过来 | 本系统设计上就规避了这类问题 |

---

## 审计方法

**三轮 > 一轮。** 每轮用不同心智模型：

1. **广度**：遍历所有文件，9 维度 checklist（内存/线程/错误/泄漏/逻辑/io_uring/fiber/池/协议）
2. **深度**：数据流追踪（每块内存从分配到释放的完整路径）+ 竞态推理（如果事件 A 和 B 同时发生？）
3. **验证**：源码逐行确认，排除假阳性

**关键：第二轮刻意不看第一轮的结果，换一个分析框架重新读。**

---

## 修复优先级

1. **数据流 bug**（错误路径泄漏、allocator 错配）— 最易触发崩溃
2. **池完整性**（freelist 损坏、gen_id 不校验）— 后果严重
3. **协议合规**（帧解析、状态机转换）— 影响面广
4. **文档**（注释、README）— 不影响运行但影响审计

---

## 验证方法

```bash
zig build          # 编译
zig build test     # 单元测试
```

**修改 StackSlot/CacheLine 布局后**，确认 comptime 检查全部通过：
- `@sizeOf(CacheLine)` = 64/128
- `@offsetOf(StackSlot, "lineN")` = 预期偏移

**修改池操作后**，验证 acquire/release 配对（所有退出路径都覆盖）。

---

## 提交格式

```
fix: <简短描述>

<详细说明：根因 + 触发条件 + 后果>
```

示例：
```
fix: protect WorkerPool stack freelist with mutex for n>1 workers

acquireStack and releaseStack operate on shared stack_freelist_top.
With multiple worker threads, concurrent access causes freelist corruption.
Fix: wrap both functions with existing pool.mutex.
Lock held only during brief freelist operations, not during fiber execution.
```

---

## 关键文件速查

| 想了解 | 看这里 |
|--------|--------|
| IO 线程主循环 | `src/http/async_server.zig:run()` |
| CQE 分发 | `src/http/async_server.zig:dispatchCqes()` |
| 连接槽位布局 | `src/stack_pool.zig` (StackSlot + CacheLine1-5) |
| Sticker 层（gen_id 校验） | `src/stack_pool_sticker.zig` |
| Fiber 上下文切换 | `src/next/fiber.zig` |
| Worker 池 | `src/next/next.zig` (WorkerPool) |
| buffer 池 | `src/buffer_pool.zig` |
| LargeBuffer 池（>32KB body） | `src/shared/large_buffer_pool.zig` |
| 出站 HTTP 客户端 | `src/client/http_client.zig` + `ring.zig` |
| DNS 解析 | `src/dns/resolver.zig` |
| WebSocket 帧 | `src/ws/frame.zig` |
| 所有常量 | `src/constants.zig` |
