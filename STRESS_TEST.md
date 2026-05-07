# 稳定性推演

## 1. Server Ring A

**正常:**
- IO 线程单线程顺序处理 CQE，无锁。
- StackPool 320MB 预分配，freelist O(1)。

**极端条件:**

| 场景 | 触发条件 | 表现 | 缓解 |
|------|---------|------|------|
| 共享栈溢出 | handler 递归/大局部变量 > 256KB | 栈帧破坏, 未定义行为 | fiber_stack_size_kb 可配; 禁止 handler 做大变量 |
| shared_fiber_active 卡死 | 前一个 fiber yield 后未 resume | 后续所有请求走 per-task stack (Next.push) | ringbuffer 4096 容量, 满则丢任务 |
| LargeBufferPool 枯竭 | 65 连接同时需要 >32KB body | acquire()=null, 413 Content Too Large | 当前上限 64, 可调大 |
| CQE ring 溢出 | cqe_seen 比内核生产慢 | 内核丢事件 → 连接静默失败 | ring_entries=2048, 需保持 dispatchCqes < 50µs/CQE |
| buffer_pool 枯竭 | 连接数超 pool_size(1024) | read 无 buffer → 连接关闭 | 当前上限 1024, 连接数超 1024 时退化 |
| Middleware/hook panic | 用户代码异常 | 连接直接关闭, 不波及其他连接 | handler 内部 try/catch |

**最脆弱点: 共享栈 256KB 限制。** 所有 handler fiber 共用 256KB 栈。fiber_stack_size_kb 可调大。

## 2. StackPool

**正常:**
- 1M slot × 384B = 384MB 预分配。
- 5 cache line 热冷分离。gen_id 幽灵防御。

**极端条件:**

| 场景 | 触发条件 | 表现 | 缓解 |
|------|---------|------|------|
| 1M 连接耗尽 | 实际连接 > 1M | slotAlloc()=null, accept 拒绝 | 理论上限, 实际 1C/300K 连接先到 CPU 瓶颈 |
| gen_id 翻转 | 28bit gen_id 用完 (2.68 亿分配) | 老 CQE 和新连接 gen_id 匹配 → 幽灵命中 | 单服务生命周期内不会发生 |
| cacheline false sharing | Worker 线程 ComputeWork 写 | IO 线程 line1 读被迫回内存 | **不会发生**: Worker 不直接写 slot, DeferredResponse 走 IO 线程队列 |
| freelist double-free | 代码 bug | 同 slot 被两条连接占用 | gen_id 防御 (前一条 gen_id 失配) |
| TTL scan 卡 IO | 1M 连接全量 scan | IO 线程阻塞 | 增量扫描 (sliding window), 每次 bounds limited |

**最脆弱点: 达到 1M 连接前 CPU 先到瓶颈。** 1C 下 300K 连接 ≈ 30% CPU (3% 活跃率)，届时 accept 开始掉。

## 3. HTTP Client + TinyCache

**正常:**
- 专用 RingB 线程 + tiny-cache 连接池。
- Fiber 串行: write → read → parse → notify。

**极端条件:**

| 场景 | 触发条件 | 表现 | 缓解 |
|------|---------|------|------|
| 池满攻击 | 瞬间 > 10K msg/s | acquire()=null → 新建连接 → store()=PoolFull → 返回 503 | 已修: MAX=10, 超出 503 |
| borrowed 串线 | Fiber A yield 时 Fiber B 借同一条 | 数据送错 fiber | 已修: borrowed 标志 + acquire 原子 |
| RingB CQE 溢出 | DNS/NATS/HTTP 共享 RingB | CQE 环满 → 事件丢失 | 独立 ring (TcpOutboundRing) 缓解, RingB 仅 HTTP |
| Fiber stack leak | Fiber 内 alloc 后异常退出 | 内存泄漏 | Fiber 不使用 general allocator, 栈上变量自动回收 |
| Pipe 无背压 | onData 快于 fiber read | Pipe buffer 无限增长 → OOM | Pipe 无背压机制 → **需加上限** |
| DNS 阻塞 | dns.resolve() 调用 getaddrinfo | 阻塞 RingB 线程 → 所有请求冻结 | 需改用 c-ares / io_uring DNS |

**最脆弱点: DNS resolve 可能阻塞 RingB 线程。** RingB 和 Ring A/C 共享同一个 DNS resolver？需要确认。

## 4. TcpOutboundRing

**正常:**
- 独立 io_uring ring, 非阻塞 tick()。
- 多连接共享: MySQL + Redis + NATS 同 ring。
- StreamHandle 或 on_read callback 出口。

**极端条件:**

| 场景 | 触发条件 | 表现 | 缓解 |
|------|---------|------|------|
| tick 饥饿 | 调用频率太低 | CQE 堆积 → ring 溢出 → 数据丢失 | 每次 event loop 必调用 tick() |
| wbuf 爆库 | 单条 write > 4KB | write()=WriteBufferFull → 数据丢弃 | wbuf 4KB, HTTP 转发 500B 不会触发; MySQL query 可能超 |
| 连接泄漏 | removeConn 未调用 | hashmap 膨胀 → 内存泄漏 | 错误路径需确保 close |
| on_read 回调卡 tick | 回调处理 > 100µs | 该 ring 所有连接延迟 | 回调必须 < 50µs; 重活走 WorkerPool |
| 单 ring 多协议 | MySQL 慢 + Redis 快 | MySQL CQE 处理快 (5µs), 不影响 Redis | tick 是顺序的但每个 CQE < 5µs, 无影响 |
| ChunkStream worker_buf OOM | StreamHandle.init 分配 64KB 失败 | panic | 预分配, init 时错误可恢复 |

**最脆弱点: wbuf 4KB 限制。** MySQL 大写入 / Redis pipeline 可能超。需提到 64KB 或支持分段 write。

## 总结

| 组件 | 最脆弱点 | 评级 | 修复优先级 |
|------|---------|------|-----------|
| Ring A | 共享栈 256KB | 🔶 中 | fiber_stack_size_kb 可调大 |
| StackPool | 1M 前 CPU 先到瓶颈 | 🟢 低 | 不修 |
| HTTP Client | DNS resolve 阻塞 RingB 线程 | 🔴 高 | 用 c-ares / io_uring DNS |
| TinyCache | Pipe 无背压 → OOM | 🔶 中 | Pipe buffer 加上限 |
| TcpOutboundRing | wbuf 4KB → 大 write 丢数据 | 🔶 中 | wbuf → 64KB 或分段写 |
