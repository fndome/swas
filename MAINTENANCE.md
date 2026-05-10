# MAINTENANCE.md — 维护指导

> `async_server.zig` 已拆分为 12 个子模块 (2725→526 行)。模块速查见底部关键文件表。

> 基于多轮深度分析 + 修复的实战经验。简洁有效。

---

## Bug 历史追踪（发现 bug 后第一件事）

**每个 bug 在动手修之前，必须先搞清楚它的来历：**

```
git log -p -S "<关键代码>" -- <文件>    # 这段代码是谁、哪个 commit 引入的？
git log --oneline -- <文件>             # 这个文件被修过几次？
```

**回答三个问题：**

| 问题 | 命令 | 常见结论 |
|------|------|---------|
| 是什么时候引入的？ | `git log -S` | 新功能附带 / merge 冲突解错 / 初版就有 |
| 之前有人试图修过吗？ | `git log --oneline -- <file>` 查找相关 commit message | 修过但没修全 / 修错了方向 / 从未被注意 |
| 当时为什么那样写？ | `git show <commit> --format=full` | 看 commit message + diff 上下文 |

**四种 bug 来源（本仓库实测）：**

| 来源 | 占比 | 特征 | 修复策略 |
|------|------|------|---------|
| **merge 冲突解错** | ~40% | `diff-tree --cc` 有合并块，双方代码都保留了 | 选边或重写，不要简单叠加 |
| **新功能附带** | ~15% | `git log -S` 定位到某个 feature commit | 理解原意图后最小改动 |
| **修了但没修全** | ~25% | 之前有个 "fix:" commit，但遗漏了某个路径 | 补全所有错误路径 |
| **从未被发现** | ~20% | 没有相关 commit，代码从初版就在 | 按正常优先级修复 |

---

## 三层系统架构

sws 不是一个简单的 WebSocket 服务器。任何改动都会跨越三层系统，必须推演每一层的影响：

| 层 | 核心概念 | 关键文件 | 典型问题 |
|---|---------|---------|---------|
| **io_uring 协议层** | SQ/CQE 时序、零拷贝、固定文件 | `event_loop.zig`, `tcp_write.zig` | SQ 满丢弃写, CQE 到但 buffer 已释放, `writev_in_flight` 跨层的 flag 生命周期 |
| **Fiber 调度层** | 共享栈、yield/resume、CAS 链表移交 | `next/fiber.zig`, `next/next.zig` | IO 线程 fiber 与 Worker 线程的栈隔离, `drainPendingResumes` 时序, `submitAndWait` vs `submit` 选择 |
| **连接状态机** | 7 状态 × 3 CQE 类型 = 21 转移 | `event_loop.zig:dispatchCqes()`, `connection_mgr.zig` | `.closing` 状态 CQE 处理器不清理 `writev_in_flight` 导致泄漏, 状态转换中 buffer 所有权转移 |

**三层不是三个模块，是三套同时生效的约束。** 改 `closeConn` 的释放逻辑，要推演：
1. io_uring 层 — 内核是否还在读这个 buffer？
2. Fiber 层 — 是否有 fiber 的 completed callback 引用了它？
3. 状态机 — `.closing` CQE handler 是否会在 flag 归零前调用 closeConn？

实际案例：closeConn 的 `writev_in_flight` 守卫涉及了全部三层的完整推演（详见最近两个 commit 的 commit message）。

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

### 怎样排除假阳性（本仓库实测 ~30% 初始报告是误报）

最常见的三类误报，验证方法：

| 误报类型 | 示例 | 正确验证方法 |
|---------|------|-------------|
| "队列会累积 zombie" | `retryPendingWrites` 跳过 null 条目 | 手推循环：空条目也会推进 `i`，最终 `shrinkRetainingCapacity` 全清 |
| "资源泄漏" | timeout 后 slot 没释放 | 检查是否是设计如此：是否有 errdefer 兜底？是否有异步回收路径？ |
| "空指针/空 optional" | `saved_call` 可能为 null | 反向追踪调用链：谁设置了这个值？调用方是否总有守卫？ |

**判断准则**：如果 `git log -S` 显示这段代码多轮审计都没人报过，大概率不是 bug，而是你的理解有问题。先问"为什么这样设计是对的"，再问"哪里可能出错"。

---

## 反向 merge 是最大的 bug 来源

**永远不要 `git merge main` 进 feature 分支。用 `git rebase main`。**

反向 merge（`Merge branch 'main' into codex/...`）造成的问题：

1. **冲突解决时容易两边都保留**：`diff-tree --cc` 的合并块里 `+` 和 ` +` 两套代码并存，导致 double-free、重复调用、冗余变量
2. **PR 变成空 merge**：feature 分支的改动被 main 已有代码覆盖，PR 贡献零 diff，fix 丢失
3. **历史污染**：graph 产生不必要的分叉，`git log --first-parent` 看不清主线

**检测存量反向 merge：**
```bash
git log --oneline --all --grep="Merge branch 'main' into"
```

**检测空 merge（fix 丢失的 PR）：**
```bash
# 对每个 PR merge commit：
git diff --stat <merge>^1 <merge>
# 输出为空 → 此 PR 的修复已丢失
```

**检测冲突解错的 merge：**
```bash
git diff-tree --cc -p <merge_commit>
# 有输出 → 存在手动解决的冲突，逐 hunk 检查是否两边都保留了
```

---

## 冲突解决检查清单

`diff-tree --cc` 输出的每个 hunk，逐条检查：

- [ ] 是否同一个变量被声明了两次？（如 `allocated` 和 `allocated_count`）
- [ ] 是否同一函数被调用了两次？（如 `handler()` + `handler()`）
- [ ] 是否清理逻辑重复？（如手动释放 + `finishXxxHandler` 内释放）
- [ ] 是否有未使用的死代码？（如 `fdSetContains` + `fdSetHas` 并存）
- [ ] 两个分支的修复方向是否不同？（如 `512 + len` vs `headerOnlyCapacity(len)`）

**核心原则：冲突解决是"选边或重写"，不是"两边都留着"。**

---

## 常见"修了但没修全"的模式

| 模式 | 示例 | 怎么补全 |
|------|------|---------|
| `catch break` 导致 fallthrough | `stream.deinit(); stream = init(...) catch break;` → break 后还走 `stream.deinit()` | 改成 `catch { ...; return; }` |
| `catch return` 在回退路径上 | `dupe(body) catch { dupe(fallback) catch return; }` → 第二层 OOM 静默 return | 回退也失败就接受灾难，但加注释说明 |
| 只加了 log 没解决问题 | `pushResume` 队列满 `log.err(...); return;` → fiber 挂起 | 扩容或降级策略 |
| 预分配不足埋雷 | `ArrayList.empty` 在热路径 `append` → OOM 丢数据 | `initCapacity` 到已知上限 |

**判断方法**：看之前的 "fix:" commit 改了哪些行，再检查相邻的 `catch` / `defer` / `return` 路径是否都覆盖了。

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
