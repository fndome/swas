# HOW_TO_FIND_BUGS.md — 深度推理方法论

> 以 sws 项目三次审计为案例，提炼系统性漏洞挖掘的思考链和最佳推理路径。

---

## 一、核心原则

### 1.1 多轮独立推理 > 单轮 exhaustive

第一轮遍历全部文件 → 第二轮完全重置视角 → 第三轮源码逐条验证。

**为什么不能只做一轮？** 人的注意力有"惯性"——第一轮建立了对代码的某种理解模型后，第二轮很难跳出这个模型看到新问题。刻意"忘记"第一轮的分析，用全新的框架重新阅读，才能发现第一轮遗漏的隐蔽问题。

三轮对比数据：
- 第一轮：34 个发现，其中 16 个真实且已修复
- 第二轮：15 个**全新**发现（第一轮未覆盖），含 2 个 HIGH
- 第三轮验证：排除 3 个假阳性，确认 25 个待修复

**如果只做一轮，会漏掉 37% 的问题（15/40）。**

### 1.2 每次推理使用不同的心智模型

| 轮次 | 心智模型 | 捕获的问题类型 |
|------|---------|--------------|
| 第一轮 | 按文件遍历 + 9 维度 checklist | 结构性问题：fiber 栈损坏、CAS 竞态、buffer 泄漏 |
| 第二轮 | 按"数据流过系统"追踪 | 数据流问题：allocator mismatch、CQE 时序、body 所有权 |
| 第三轮 | 按"假设-验证"逐条确认 | 真实性判断：排除假阳性、确认真问题 |

**关键：第二轮不是"再检查一遍"，而是换一个完全不同的分析框架。**

---

## 二、9 维度 Checklist（第一轮使用）

这是"广度优先"的检查框架。对每个文件依次问：

### 2.1 内存安全
```
- 每个 alloc/free 是否配对？
- 每个指针解引用前是否有 null 检查？
- 切片操作是否在边界内？ [offset..offset+len] 是否 ≤ buf.len？
- 是否有 allocator mismatch？（A 分配 B 释放）
- 是否有 use-after-free？（释放后仍持有指针）
```

### 2.2 线程安全
```
- 哪些数据在 IO 线程访问？哪些在 worker 线程访问？
- 共享数据是否有互斥锁或原子操作保护？
- threadlocal 变量是否真的 per-thread 隔离？
- CAS 操作的重试是否检查了每次结果？
```

### 2.3 错误处理
```
- 每个 try/catch 分支是否释放了已分配的资源？
- @panic("OOM") 是否在生产热路径中？
- 静默忽略的错误（`_ = ... catch {}`）是否安全？
- 错误返回值是否被正确传播？
```

### 2.4 资源泄漏
```
- fd 是否在所有路径都被 close？
- io_uring buffer 是否在 close 路径被 markReplenish？
- pool acquire 后的 release 是否覆盖所有退出路径（含异常）？
- ArrayList/hashmap 是否在 deinit 前清空？
```

### 2.5 逻辑正确性
```
- 状态机转换是否合法？（reading→processing→writing→closing）
- bool 条件是否反了？
- 比较操作符是否正确？（>= vs >, == vs !=）
- 并发状态下的 if-check-then-act 是否有 TOCTOU 窗口？
```

### 2.6 io_uring 语义
```
- SQE 创建后是否有对应的 submit()？
- CQE 处理后是否有 cqe_seen()？
- user_data 编码是否避免碰撞？（不同模块的 flag bit 不重叠）
- CLOSE_USER_DATA_FLAG 是否在所有 close 路径使用？
- LINK_TIMEOUT 是否在需要超时的 SQE 上设置？
```

### 2.7 Fiber/栈安全
```
- shared_fiber_active 的 set/clear 是否在正确的上下文中？
- fiber yield 后共享栈是否被保护？（不能再分配新 fiber）
- fiber resume 前 gen_id 是否匹配？（slot 可能已被重用）
- 非 fiber 上下文是否可能意外调用 yield？
```

### 2.8 池完整性
```
- acquire/release 是否配对？
- freelist push/pop 是否正确？（无 double-push、无丢条目）
- gen_id 是否在 slotFree 时清零？
- live list 的 swap-remove 是否更新了被移动元素的 index？
```

### 2.9 协议解析
```
- 恶意输入（超长字段、负数长度、控制字符）是否有防护？
- 解析失败后是否继续处理？（应该 return error）
- 帧/消息边界是否正确识别？
```

---

## 三、数据流追踪法（第二轮使用）

这是"深度优先"的分析方法。核心思想：**数据不会自己消失——追踪每一块内存从分配到释放的完整生命周期。**

### 3.1 标记关键数据类型

识别项目中的关键内存对象：
- `large_buf`（LargeBufferPool 分配）
- `response_buf`（BufferPool 分配）
- `write_body`（GeneralPurposeAllocator 分配）
- `ctx.body`（来源不定）
- `StackSlot`（StackPool 管理）

### 3.2 追踪每个类型的完整生命周期

对每种类型画出其路径图：

```
large_buf:
  LargeBufferPool.acquire()
    → onReadComplete (body overflow)
      → slot.line3.large_buf_ptr = @intFromPtr(buf.ptr)
        → onBodyChunk → 读满 → processBodyRequest
          → t.body_data = buf      ← ⚠️ 所有权转移
            → httpTaskExec → ctx.body = t.body_data
              → ctx.deinit() → self.allocator.free(b)  ← ⚠️ allocator 不对！
```

**关键发现**：追踪到 `ctx.deinit()` 时发现它在用 `self.allocator`（GPA）释放 `large_buf`（LargeBufferPool 分配）——这是 H-1 的根因。

### 3.3 在所有权转移点检查

每当看到一个赋值如 `a = b` 或 `ctx.body = t.body_data`，问：
- 这是所有权转移还是借用？
- 如果是转移：原持有者是否还持有引用？
- 如果是借用：借出期间原持有者是否可能被释放？
- 最终谁负责释放？他用的 allocator 是否正确？

---

## 四、竞态推理法

### 4.1 识别"两个事件同时发生"的场景

对每个关键操作，问"如果此时另一个线程/中断/CQE 同时做了什么，会怎样？"

```
closeConn(fd) 提交 close SQE
    同时
读 CQE 到达 → onReadComplete → submitRead(fd)  -- fd 即将被 close！
```

这发现了 DF-1（close/read CQE 竞态）。虽然当前有 `.closing` 状态保护，但保护生效的时机（`closeConn` 设置 state 之后）和 SQE 提交之间仍有窗口。

### 4.2 检查原子操作的配对

对每个 atomic store，找到对应的 atomic load，检查：
- memory ordering 是否匹配？(release → acquire)
- 是否遗漏了必要的 fence？
- 非原子变量的访问是否在原子保护区域内？

```
@atomicStore(u8, &slot.line4.writev_in_flight, 1, .release);  // submitWrite
...
@atomicLoad(u8, &slot.line4.writev_in_flight, .acquire);      // ensureWriteBuf
```

### 4.3 线程间共享数据的读写路径

```
stack_freelist_top (WorkerPool):
  acquireStack: top -= 1; return pool[freelist[top]];
  releaseStack: scan pool → freelist[top] = idx; top += 1;
```
- 同一时刻两个 worker 线程都调 releaseStack → `top` 读写竞争
- 连同一个 worker acquireStack + 另一个 releaseStack → pool 元素竞争

---

## 五、假阳性识别法（第三轮使用）

### 5.1 源码逐行验证

不信任推理，必须看到代码。

**案例 ML-2（DeferredResponse body 泄漏）**：
- 推理：`respondZeroCopy` 失败 → closeConn → body 不释放
- 验证：`respondZeroCopy` line 1868：`self.allocator.free(body)` — 已释放 ✅
- 结论：**假阳性**。推理忽略了 `ensureWriteBuf` 失败分支中的 `free(body)`

### 5.2 假阳性的常见模式

| 模式 | 示例 | 为什么误判 |
|------|------|-----------|
| 忽略了代码中已有的保护 | DF-3 跨连接污染 | sticker.getSlotChecked 已有 gen_id 校验 |
| 只读了主路径忽略了错误分支 | ML-2 body 泄漏 | ensureWriteBuf 失败分支有 free(body) |
| 假设了错误的线程模型 | CB-2 RingB 安全 | 实际全部在 RingB IO 线程运行 |
| 混淆了不同的 allocator | FS-2 allocator mismatch | 确认后发现确实是同一 allocator 但绕过 pool |

### 5.3 验证 checklist

对每个"发现"，依次确认：
1. 这个路径真的会被执行吗？（调用链完整性）
2. 这个保护真的不够吗？（检查所有相关 guard）
3. 这个 allocator 真的是错的吗？（追踪 allocator 来源）
4. 这个竞态真的有实际窗口吗？（检查状态机转换时机）

---

## 六、最佳推理路径总结

```
第一轮（广度）
  └─ 用 9 维度 checklist 遍历所有文件
  └─ 输出：初步发现列表（含大量已完成修复）

第二轮（深度）
  └─ 切换心智模型：数据流追踪 + 竞态推理
  └─ 重新阅读全部代码
  └─ 输出：新发现列表（侧重第一轮遗漏的隐蔽问题）

第三轮（验证）
  └─ 合并两轮发现
  └─ 逐条源码验证：真的存在吗？
  └─ 排除假阳性
  └─ 输出：确认的问题列表（CURRENT.md）
```

### 每次推理的关键动作

1. **读代码时不记笔记**——先完整理解，再回头标记问题。边读边记会打断深度推理流。
2. **提问驱动**——不是"这里有没有 bug"，而是"这个变量从哪来？谁释放它？如果此时发生 X 会怎样？"
3. **写出来**——推理在脑中是模糊的，写下来才清晰。每个发现的"位置+推理+后果"三段式强制精确。
4. **独立验证**——第二轮刻意不看第一轮的结果。如果两轮独立发现同一问题，说明问题显著；如果仅一轮发现，需重点验证。

### 不该做的事

- ❌ 在同一轮分析中反复切换分析框架（会混淆思维）
- ❌ 信任代码注释而不看实现（注释可能过时：flushWsWriteQueue）
- ❌ 假设"这段太简单不会有 bug"（简单代码更容易被跳过）
- ❌ 跳过"看起来已经有人修过"的模块（可能是部分修复）
- ❌ 只用一种心智模型（线性阅读、数据流、时序、所有权……轮流用）

---

## 七、根因分析：为什么代码会变成这样？

> 找到 bug 只是第一步。理解 **为什么代码当前是这个状态**——什么力量把它推到了这个位置——才能从根本上防止同类问题再次出现。

### 7.1 双模张力：微服务 vs 单体的同一份代码

这是 sws 项目最深层的矛盾来源。

**现象**: 每个服务模块（order、payment、service-product、settlement 等）都独立注册 `/health` 路由，在微服务部署时各有自己的进程和端口——完全正确。但在 standalone 模式下，所有模块共享一个 gin engine → 路由冲突 → panic。

**为什么这样**：模块被设计成"独立可部署的微服务"，代码层面通过 `RegisterRoutes(r *gin.Engine)` 暴露接口。这个抽象在微服务模式下完美工作（每个 `r` 是不同的 gin engine）。当引入 standalone 模式时，所有模块的 `RegisterRoutes` 被传入同一个 `r`，但没有人回过头去检查"这些模块假设了独占 engine 吗？"

**同类问题**：
- `remote.TagClient.ListTags()` 调用 `/tag/list` → standalone 下需要 JWT auth，但 remote client 不带 token
- 数据库配置：每个模块有自己的 `config/application-test.yml`，standalone 用命令行参数覆盖
- 数据库名称：migration SQL 中 `USE user` / `USE timeline` 假设独立 database，standalone 全在 `gaming_partner` 一个库

**推理技巧**: 当看到 `RegisterRoutes(r)` 这种"注入依赖"的模式时，问：**注入的是同一个实例还是不同实例？如果是同一个，每个调用者假设了什么？**

---

### 7.2 增量特性叠加：每一层都正确，层间交互无人验证

**现象**: `LargeBufferPool`（自己管理内存块）→ `processBodyRequest`（取一块给 body）→ `httpTaskExec`（设 `ctx.body = body_buf`）→ `ctx.deinit()`（`allocator.free(ctx.body)`）。

每一层的代码单独看都合理：
- LargeBufferPool: "我分配内存块，调用者负责 release"
- processBodyRequest: "我把 body 传给 handler 上下文"
- httpTaskExec: "我用 ctx.body 存 body，结束时 deinit 释放"
- ctx.deinit: "我释放 ctx.body"

但**层间传递了所有权且 allocator 信息丢失了**。`ctx.deinit` 不知道 `ctx.body` 来自 LargeBufferPool，它用的是自己的 `self.allocator`。

**为什么这样**：Context 是通用抽象，设计时只考虑了"handler 通过 text/json/html 设置 body"这一种路径。body 的来源是 `allocator.dupe()`。后来加入 LargeBufferPool 支持超大 body 时，复用了 Context 的 `body` 字段，但没有区分"这个 body 是 dupe 的还是 pool 的"。

**推理技巧**: 追踪一个值从出生到死亡的完整路径时，特别关注**"类型信息丢失"点**——`[]u8` 看不出它来自哪个 allocator，`?[]u8` 看不出它是否 nullable-by-design。

---

### 7.3 单线程假设与多线程现实的错位

**现象**: `WorkerPool.stack_freelist` 的 `acquireStack` / `releaseStack` 没有互斥锁，但被多个 worker 线程并发访问。`LargeBufferPool` 的 `release` 加了 CAS 原子操作，但 `freelist_top += 1` 是非原子的。

**为什么这样**：项目核心设计是"单 IO 线程"，绝大部分代码在这个范式下是线程安全的。worker pool 是后来加入的"卸货"机制——CPU 重活扔给后台线程。但**引入多线程时没有全面审查哪些共享数据变成了并发访问**。

具体来说：
- `stack_freelist` 在 WorkerPool 内部，IO 线程不访问 → 但多个 worker 线程同时访问 → 没有锁是 bug
- `LargeBufferPool` 的 `acquire/release` 原本只在 IO 线程调用 → 加了 CAS 是防御性编程 → 但 `freelist_top` 忘了

**推理技巧**: 搜索项目中所有 `Thread.spawn` 或 worker 线程入口，然后追踪这些线程访问的**所有**共享变量，逐一检查同步机制。IO 线程和 worker 线程之间的数据流（invoke、deferred response）也要逐条检查。

---

### 7.4 Schema/代码/文档三向不一致

**现象**: 
- `t_guild` 表缺少 `description/tag_ids/main_games/online_count` 列，但 Go struct 有这些字段
- README 写 StackSlot 320 bytes，实际 384 bytes
- README 写 fiber stack 默认 64KB，实际 256KB
- `CacheLine2` 声明了 `prev_live/next_live` 字段但全项目无任何读写
- 注释写"四组子结构"实际是五组

**为什么这样**：代码是**活文档**——struct 定义是唯一真相（编译器强制）。SQL migration 和 README 是**死文档**——改了代码不改它们，不会立即报错。

**演进路径**：
1. 最初设计：t_guild 只有基本字段（id, name, logo, owner_id, status）
2. 后来需求：需要标签、主推游戏、简介 → Go struct 加了字段
3. 再后需求：需要在线人数 → struct 又加字段
4. 再后需求：公会余额 → migration 加了 `balance` 列，但 struct 忘加了
5. 每个步骤都可能有人更新 Go struct，但 migration SQL 和 README 落下了

**推理技巧**: 对每个 struct 字段，搜索全项目确认它被读写。**不被读写的字段是死代码**（如 prev_live/next_live），**被读写但 migration 没有的字段是 schema 不一致**。反过来，**migration 有但 struct 没有的字段**（如 balance，后来补上了）是查询会失败的根因。

---

### 7.5 安全策略的"一刀切"副作用

**现象**: `ORDER_CRYPTO_KEY` 环境变量未设置 → `panic` 拒绝启动。策略目标是"生产环境必须显式设置密钥，禁止默认值"。但 standalone 开发模式也受影响。

**为什么这样**：安全策略被编码为**二态开关**（有密钥 / panic），没有"开发模式"的第三种状态。正确的设计是三态的：生产缺密钥 → panic；开发缺密钥 → 用固定测试密钥 + WARN 日志。

**同类问题**：
- `@panic("OOM")` 在 init 路径中：开发机内存够 → 永远不触发；生产 OOM → 整个进程崩溃而非优雅降级
- `writev_in_flight` 检查在 `ensureWriteBuf` 中返回 false → 调用者收到"分配失败"但没有重试机制

**推理技巧**: 搜索所有 `panic(` / `@panic(` 调用，问"这个 panic 在什么条件下触发？触发后整个进程死了，有没有更好的处理方式？"

---

### 7.6 拷贝-粘贴式的模块复制

**现象**: order、payment、service-product、settlement、billing、recon 六个模块的 `router.go` 都有几乎相同的健康检查注册代码：
```go
health := r.Group("/health")
health.GET("", HealthCheck)
health.GET("/ready", ReadinessCheck)
```

每个模块也有几乎相同的 `internal/mysql.go`、`internal/redis.go`、`config/application-test.yml`。

**为什么这样**：微服务架构下每个模块是独立项目，拷贝模板是最快的启动方式。但拷贝后**没有抽象公共部分**——每个模块都有自己的一份 `Db *sqlx.DB`、`RDB *redis.Client`、`Conf *AppConfig`。standalone 模式通过 `go:linkname` 强行注入共享连接来弥合这种分裂。

**推理技巧**: 看到高度相似的代码块时，不要跳过——它们是最容易有"拷贝了但没适配"的 bug 的地方。比较每个拷贝版本，找不一致之处。

---

### 7.7 Happy Path 测试覆盖，Error Path 推理覆盖

**现象**: 
- `pending_bid` 泄漏：正常路径 `submitRead` 成功 → 下次 `onReadComplete` 回收。错误路径 `submitRead` 失败 → `closeConn` → 不回收。
- `flushReplenish` 丢 bids：正常路径全部 provide → clear。错误路径中途失败 → 剩下的丢了。
- `ensureWriteBuf` 替换 in-flight buffer：正常路径 buffer 够大 → 不替换。错误路径 buffer 不够 → 替换时不检查 in-flight。

**为什么这样**：写代码时心智模型是"正常情况下 A → B → C"。错误处理是后来补的，通常只覆盖了最明显的错误路径，没有遍历所有可能的失败组合。

**推理技巧**: 对每一个 `.catch` / `try` / `if err != nil` 分支，单独画出"从这里开始，已经分配了哪些资源？这些资源由谁释放？"的清单。这是发现资源泄漏最有效的方法。

---

### 7.8 根因速查表

| 看到的症状 | 可能的根因 | 重点检查 |
|-----------|-----------|---------|
| 同一路径注册多次 | 双模张力（微服务+单体） | 检查 `RegisterRoutes` 的接收者是否同一实例 |
| 类型转换/allocator 不匹配 | 增量特性叠加 | 追踪值的完整生命周期，标记所有权转移点 |
| 非原子变量在多线程中读写 | 单线程假设被打破 | 搜索 Thread.spawn → 追踪其访问的所有共享变量 |
| 文档与代码不一致 | Schema/代码/文档三向漂移 | 以 struct 定义和 comptime check 为唯一真相 |
| panic 在开发环境触发 | 安全策略二态化 | 搜索所有 panic，评估是否需要三态 |
| 六份几乎相同的代码 | 拷贝-粘贴式模块复制 | 逐份比较，找不一致之处 |
| 正常路径 OK，错误路径泄漏 | Happy path 测试驱动 | 对每个 catch 分支列出"已分配未释放"清单 |

---

### 7.9 修复优先级原则

理解了"为什么这样"之后，修复策略应该是**根因导向**而非**症状导向**：

1. **先修架构级问题**（双模张力、单线程假设）→ 消除同类 bug 的产生土壤
2. **再修数据流问题**（allocator 绕过、所有权丢失）→ 这些是最容易导致 crash 的
3. **后修资源泄漏**（buffer 泄漏、fd 泄漏）→ 慢性的，但在长时间运行后会累积
4. **最后修文档**（README、注释）→ 虽然不影响运行，但错误文档会产生更多 bug

---

## 八、系统原生并发模型：抛弃通用多线程假设

> 这是本次审计最重要的方法论教训。前两轮分析中我犯了一个根本错误：
> **把通用多线程系统的经验（"共享变量需要锁"、"bool 需要 atomic"）直接套用到了一个精心设计为单线程+显式移交点的系统上。**
>
> 正确的做法是：**先画出本系统实际的时序图，再判断并发是否存在。**

### 8.1 sws 的实际并发模型

```
┌─ IO Thread (唯一，绑核) ─────────────────────────────┐
│                                                        │
│  StackSlot[]  Connections  BufferPool  LargeBufferPool │
│  Ring A       WsServer     Middlewares  DNS Resolver   │
│  Next.ringbuffer (SPSC，但单线程使用)                    │
│                                                        │
│  while (!should_stop):                                 │
│    submit + copy_cqes + dispatchCqes                   │
│    drainPendingResumes                                 │
│    drainNextTasks (IO thread push, IO thread pop)      │
│    drainTick → invoke.drain (worker 线程 push 的收件箱) │
│    ttlScanTick                                         │
└────────────────────────────────────────────────────────┘
         ↑ invoke.push (CAS 无锁链表，任意线程安全)
┌─ Worker Threads (0..N, 默认 0 或 1) ──────────────────┐
│  workerLoop: pop task → runTask → 完成                  │
│  只访问: WorkerPool 内部状态 (task queue + stack pool)   │
│  不访问: IO 线程的任何数据结构                           │
└────────────────────────────────────────────────────────┘
```

**关键事实**：
1. IO 线程和 worker 线程**不共享任何数据**。它们通过两个显式移交点通信：
   - `Next.submit()` → WorkerPool.submit (mutex 保护) → worker pop
   - Worker 完成 → `invokeOnIoThread` → InvokeQueue (CAS 无锁) → IO drainTick
2. 移交是**单向的**：IO→Worker 和 Worker→IO，没有"同时读写同一变量"的情况
3. `Next.go()` 的 ringbuffer **实际上是单线程的**：IO 线程 push，IO 线程 pop (`drainNextTasks`)

### 8.2 基于此模型重新审计：我错了什么

| 原判定 | 实际 | 原因 |
|--------|------|------|
| shared_fiber_active 应该 atomic | **不需要** | 仅在 IO 线程读写。per-task 路径已修复为不碰它 |
| WorkerPool stack_freelist HIGH | **MEDIUM** | 仅 n > 1 触发。系统设计为 n = 1（README 推荐）。默认不触发 |
| HttpClient 线程安全 HIGH | **N/A** | HttpClient 是独立出站组件，不在主 IO 循环内。调用者在自己的线程 busy-wait（设计如此） |
| RingB invoke 并发竞争 | **不存在** | InvokeQueue 是 CAS 无锁链表，多生产者单消费者，设计上就是安全的 |
| CB-1 可见性问题 | **不存在** | 两线程不共享变量，可见性由队列移交保证 |

### 8.3 "时间衔接处"分析方法

用户指出的关键：**不要问"是否有并发"，要问"在同一时间点，两个执行流是否访问同一内存"。**

对每对 (执行流A, 执行流B)，画出时间线：

```
例：IO 线程 vs Worker 线程

IO: ──[submit task]──[处理 CQE]──[drain invoke]──[处理 CQE]──
                           ↑                      ↑
Worker: ──[pop task]──[计算]──[invoke.push]──[pop next]──
                           ↑ 移交点 1          ↑ 移交点 2
```

- **移交点 1** (submit → pop)：通过 mutex 保护的队列，**先后关系**，不存在同一时间点重合
- **移交点 2** (invoke.push → drain)：通过 CAS 链表，worker push 和 IO drain 可能在同一时间，但链表操作是原子的

IO 线程和 worker 线程在时间轴上**唯一可能的重合**：worker 在 push invoke 的同时，IO 在 drain invoke。但这是 CAS 链表 → 安全。

### 8.4 WorkerPool 内部的真实竞争（唯一确认的并发）

```
Worker 1: ──[pop task]──[acquireStack]──[fiber]──[releaseStack]──
Worker 2: ──[pop task]──[acquireStack]──[fiber]──[releaseStack]──
                         ↑ 重合！           ↑ 重合！
```

但注意：这仅在 `initPool4NextSubmit(n > 1)` 时存在。默认 `n = 1` → 不存在 Worker 2 → **不存在重合**。

**正确的严重度**: 不是 HIGH（通用多线程系统的视角），而是 MEDIUM（本系统的实际设计意图是 n=1）。

### 8.5 教训：系统原生的并发分析步骤

```
1. 画出所有执行流（线程/fiber/中断上下文）
2. 标注每个执行流访问的数据
3. 找出跨执行流共享的数据（本系统中几乎没有！）
4. 对每个共享数据，判断是"先后"还是"同时"
   - 先后 → 找衔接处的原子性（移交是否完整？）
   - 同时 → 找同步机制（锁/原子/CAS？）
5. 不要假设"多线程 = 需要锁"
   - 先确认是否真的多线程访问
   - 再确认是否真的同时（而非先后）
```

**本系统最关键的发现**: 90% 的"线程安全"担忧是本系统不存在的——因为它的设计就是**单线程 + 显式单向移交**。真正需要关注的只有 WorkerPool 内部（worker 之间的竞争），且仅在 n > 1 时触发。
