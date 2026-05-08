# MAINTENANCE.md — 维护指导

> `async_server.zig` 已拆分为 12 个子模块 (2725→526 行)。模块速查见底部关键文件表。

> 基于 8 轮深度分析 + 20 项修复的实战经验。简洁有效。

---

## 四层系统架构

sws 不是一个简单的 WebSocket 服务器。任何改动都会跨越四层系统，必须推演每一层的影响：

| 层 | 核心概念 | 关键文件 | 典型问题 |
|---|---------|---------|---------|
| **io_uring 协议层** | SQ/CQE 时序、零拷贝、固定文件 | `event_loop.zig`, `tcp_write.zig` | SQ 满丢弃写, CQE 到但 buffer 已释放, `writev_in_flight` 跨层的 flag 生命周期 |
| **Fiber 调度层** | 共享栈、yield/resume、CAS 链表移交 | `next/fiber.zig`, `next/next.zig` | IO 线程 fiber 与 Worker 线程的栈隔离, `drainPendingResumes` 时序, `submitAndWait` vs `submit` 选择 |
| **连接状态机** | 7 状态 × 3 CQE 类型 = 21 转移 | `event_loop.zig:dispatchCqes()`, `connection_mgr.zig` | `.closing` 状态 CQE 处理器不清理 `writev_in_flight` 导致泄漏, 状态转换中 buffer 所有权转移 |
| **K8s 路由层** | 虚节点环、headless DNS、NodePort 亲和 | `k8s/pod_hash.zig`, `k8s/router_hash.zig` | Go/Zig 两端 `trunc32` 不一致导致路由漂移, DNS 模板与 ConfigMap 不同步 |

**四层不是四个模块，是四套同时生效的约束。** 改 `closeConn` 的释放逻辑，要推演：
1. io_uring 层 — 内核是否还在读这个 buffer？
2. Fiber 层 — 是否有 fiber 的 completed callback 引用了它？
3. 状态机 — `.closing` CQE handler 是否会在 flag 归零前调用 closeConn？
4. K8s 层 — 跨 Pod 转发是否有 buffer 被引用？

实际案例：closeConn 的 `writev_in_flight` 守卫涉及了前三层的完整推演（详见最近两个 commit 的 commit message）。

---

## 维护流程（每次至少 3 轮）

```
第一轮：全面阅读 + 深度推理
  └─ 读完 src/ 下每个 .zig 文件
  └─ 切换心智模型（广度 checklist → 数据流追踪 → 竞态推理）
  └─ 输出：完整漏洞/BUG 列表

第二轮：多维度比较 + 分级
  └─ 按触发概率 × 后果严重度 = 真实风险排序
  └─ 剔除假阳性（必须源码验证，不可凭推理）
  └─ 剔除"在本系统并发模型下不成立"的误判
  └─ 输出：优先级列表，标记最高风险的 1 个

第三轮：修复 + 验证 + 提交
  └─ 只修最高风险的第一个问题
  └─ 多维度确认修复方案正确（不引入新问题）
  └─ zig build 通过
  └─ git commit（一个 commit 一个问题）
  └─ 循环：如果还有问题，回到第二轮取下一个
```

**为什么一次只修一个？** 批量修复增加回归风险，且难以追溯哪个修改导致了新问题。逐个修复、逐个验证、逐个提交。

**为什么至少 3 轮？** 单轮分析命中率约 47%（按本仓库历史数据：第一轮 34 发现修 16）。第二轮切换心智模型可提升至 ~70%。第三轮源码验证可排除假阳性。

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

## 修改代码后：加英语注释

每条修改都必须在改动点加上**简要英语注释**，说明为什么这么写。注释只写"为什么"，不写"是什么"（代码本身说了"是什么"）。

反例（无注释）：
```zig
self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
```

正确：
```zig
// CQE means kernel is done — clear flag for closeConn & retry
self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
```

理由：sws 的修改涉及四层约束，未来维护者（包括 3 个月后的自己）如果不看 commit message 就无法理解意图。注释是跨时间的沟通。

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
| IO 线程主循环 | `src/http/event_loop.zig:run()` |
| CQE 分发 | `src/http/event_loop.zig:dispatchCqes()` |
| 连接槽位布局 | `src/stack_pool.zig` (StackSlot + CacheLine1-5) |
| Sticker 层（gen_id 校验） | `src/stack_pool_sticker.zig` |
| Fiber 上下文切换 | `src/next/fiber.zig` |
| Worker 池 | `src/next/next.zig` (WorkerPool) |
| buffer 池 | `src/buffer_pool.zig` |
| LargeBuffer 池（>32KB body） | `src/shared/large_buffer_pool.zig` |
| 出站 HTTP 客户端 | `src/client/http_client.zig` + `ring.zig` |
| DNS 解析 | `src/dns/resolver.zig` |
| WebSocket 帧 | `src/ws/frame.zig` |
| HTTP 路由 + Fiber 分发 | `src/http/http_routing.zig` |
| TCP read/header 解析 | `src/http/tcp_read.zig` |
| 连接管理 | `src/http/connection_mgr.zig` |
| 所有常量 | `src/constants.zig` |
