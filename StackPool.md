# StackPool 设计

在 1M 连接的量级下，StackPool 的 400 字节，本质是为了存两个最关键的"锚点"以及维持它们运行的最小状态。

---

## 1. 身份锚点：用户 ID (User ID)

在 IM 系统中，连接（FD）是无意义的，用户 ID 才是业务逻辑的核心。

- **映射关系**：当 io_uring 告诉你 `fd: 123` 有消息时，你必须瞬间知道这是"张三"发的。
- **为什么存这？** 不能每次都查数据库。存入 StackPool 后，通过 `user_data` 拿到索引，1 纳秒就能知道发消息的是谁。
- **分布式路由**：如果用户 ID 在这，你解析完私聊目标后，能立刻判断目标是在当前 Pod 还是需要转发。

---

## 2. 物理锚点：`*conn` (连接状态/句柄)

这里的 `*conn` 在 io_uring 架构下表现为：

- **Socket FD**：物理操作的目标。
- **Generation ID (世代 ID)**：这是**极其重要**的安全锁。

> **场景**：FD 123 刚断开，内核立刻把 FD 123 分配给了新用户。如果旧的 io_uring 异步事件此时才回来，没有 Generation ID 对比，你就会把新用户的数据当成旧用户的处理，导致**串号/信息泄露**。

- **2000ms 计时器**：存生日，执行过期斩断逻辑。

---

## 3. 异步"断点" (The Continuation)

这是 io_uring 这种 Proactor 模式的刚需。因为 IO 是异步的，这 400 字节要记录"上次干到哪了"：

- **写缓冲区进度**：如果一条大消息发了一半（EAGAIN），记录剩余字节的偏移量。
- **HttpClient 引用**：如果正在帮这个用户调微服务，存一个借来的 httpClient 的 ID，等回调回来时能接得上。

---

## 为什么这 400 字节比 Go 的指针更高效？

| Go | Zig |
|----|-----|
| `map[int]*Conn` | `pool[idx]` |
| 哈希计算 + 锁竞争 + 指针跳转 | 一次内存偏移（`base + idx * 400`） |
| 缓存不友好 | **缓存友好** — UserID 和 FD 在内存里挨在一起，CPU 预取一次性全拿走 |

---

## 设计代码（先跑通再挪走）

```zig
const HttpStack = struct {
    // 纯净层（需对齐缓存）：fd、gen_id、state、last_active_ms
    header: StackHeader,
    // 业务胶水层（留在 Server 里）
    plugin_data: ServerData,
};
```

---

## 三个核心切入点

### 切入点一：user_data 索引化（唯一通信凭证）

这是 io_uring 与 Stack Pool 的"挂钩"处。

- **不要传指针**：在 io_uring 提交（SQE）时，`user_data` 必须直接填入 Stack Pool 的数组下标（`u32 index`）。
- **理由**：当你从 CQE 拿到结果时，index 让你能以 O(1) 的速度、零 CPU 缓存抖动地定位到那 400 字节。这是单线程能跑出极限吞吐的物理基础。

### 切入点二：世代 ID (Generation ID) 校验机制

在 Java/Go 里，对象引用是安全的。但在 Zig 的原始内存池里，FD 会复用，索引也会复用。

设计逻辑：
- 这 400 字节里必须有一个 `gen_id`
- **提交请求时**：`user_data = (gen_id << 32) | index`
- **回收请求时**：对比 `cqe.user_data` 里的 `gen_id` 是否等于当前池中该位置的 `gen_id`

**理由**：这是解决"幽灵事件"（旧请求的 CQE 在连接断开并重新分配后才返回）的唯一手段，也是防止 1M 连接下数据错乱的死穴。

### 切入点三：空闲链表的静态化 (Free-list)

在 1C 环境下，不能为了找一个空位而去遍历 1M 的数组。

- **实现方式**：在程序启动时，将所有空闲的 index 串成一个简单的栈（用一个 `u32` 数组存储所有可用的下标）。
- **acquire**：`stack_top -= 1`
- **release**：`stack_top += 1`

这保证了在单核上，内存分配的开销是恒定的纳秒级，完全不占用业务解析的 CPU 时间。

> 为什么在 io_uring 里写它更麻烦？因为你是在**手动实现一个"微型操作系统"的内存管理单元（MMU）**。

---

## 总结

StackPool 就是一个高效的**上下文容器**：

- **UserID** — "谁在说话"
- **FD + GenID** — "往哪回话"
- **400 字节** — "话说到哪了"

在 1C 环境下，把 100 万个活跃的"人"变成 100 万个静态的"结构体"。没有动态查找，CPU 才能腾出空去处理共享栈解析。

---

## 建议

- **UserID 用 `u64`**（不是字符串），省下空间给状态机用。
- 在 400 字节里增加 `prev_idx` 和 `next_idx`，组成**双向链表索引**串联"已建立连接"，遍历 TTL 时不用扫空位。

---

## 4. Buffer 归属权与 Double-Free 防御

### 问题场景

```
submitWrite（短写）→ CQE(res=500) → onWriteComplete → resubmit → ...
                                                                    ↓
                                   2000ms TTL 到期 → closeConn → 释放 Buffer
                                                                    ↓
                                   延迟 CQE 回来 → onWriteComplete → 再次释放 → DOUBLE FREE
```

io_uring 的异步性决定了：**close 触发的内核取消操作，与已经在队列里的 CQE 之间存在竞态窗口。**

### 终极防御：`buf_recycled` 标志位

在每连接上下文里加一个单比特锁：

```zig
const SlotHeader = packed struct {
    gen_id: u32,
    buf_recycled: bool,   // ← 0：未回收  1：已回收
    _pad: u7,
};
```

**所有 buffer 回收路径的核心守卫：**

```zig
fn recycleBuffer(slot: *Slot) void {
    if (slot.header.buf_recycled) return;   // ← 第二次调用直接跳过
    slot.header.buf_recycled = true;
    // 归还给内核 / 对象池
    markReplenish(slot.read_bid);
}
```

### 回收权归属表

| 路径 | 谁回收 | 条件 |
|------|--------|------|
| 正常写完 | `onWriteComplete` 的 `offset >= total` 分支 | 数据全发完 |
| 正常读完 | `httpTaskComplete` / `wsTaskComplete` | Fiber 处理完毕 |
| 异常关闭 | `closeConn` 第二次调用（close CQE 回包后） | `state == .closing` 且 `!buf_recycled` |
| 幽灵 CQE | dispatch 看到 `state == .closing` 且 `IORING_CQE_F_BUFFER` | 内核返回的 buffer ID，回收后设 flag |
| 闲置超时 | `checkIdleConnections` → closeConn → 同上 | 不用直接 free，走 closing 流程 |

### 核心原则

> **Buffer 的回收权归 CQE 的最后一声哨响。** 无论正常路径还是异常路径，`buf_recycled` 只允许一次 `true`。

---

## 5. swas StackPool 模块

位于 `src/stack_pool.zig`：

```zig
pub fn StackPool(comptime T: type, comptime capacity: usize) type {
    // O(1) acquire / release
    // user_data = (gen_id << 32) | idx
    // 缓存行对齐，freelist 静态化
}
```

**核心 API：**

| 方法 | 说明 |
|------|------|
| `init(allocator)` | 预分配 `capacity` 个 `T` 槽位 + freelist |
| `acquire() ?u32` | 弹出一个空闲索引，O(1) |
| `release(idx)` | 归还索引，O(1) |
| `packUserData(gen_id, idx) u64` | 打包 SQE user_data |
| `unpackGenId(ud) u32` | 从 CQE user_data 解 gen_id |
| `unpackIdx(ud) u32` | 从 CQE user_data 解 index |

**Ghost Event 防御：**

```zig
const idx = unpackIdx(cqe.user_data);
const slot = &pool.slots[idx];
if (unpackGenId(cqe.user_data) != slot.header.gen_id) {
    // 幽灵事件 — 旧连接的 CQE，slot 已分配给新连接
    continue;
}
```

---

## 6. AsyncServer 集成 StackPool（架构迁移方案）

### 当前 vs 目标

| | 当前 (`AutoHashMap`) | 目标 (`StackPool`) |
|---|---|---|
| 连接查找 | `hash(conn_id)` → O(1) 均值，cache miss | `slots[idx]` → O(1) 确定，cache hit |
| 内存布局 | 散列分布，指针跳跃 | 连续数组，CPU 预取友好 |
| user_data | `conn_id` (u64 自增) | `(gen_id << 32) | idx` |
| 幽灵事件防护 | `connections.getPtr` 判 null（不防复用竞态） | `unpackGenId(cqe.user_data) != slot.gen_id` |
| 内存上限 | 无上限（动态增长） | `capacity` 固定，OOM 直接拒绝 |

### AsyncServer 泛型化

```zig
pub fn AsyncServer(comptime T: type) type {
    return struct {
        const Self = @This();

        // 预分配静态池，T 是 IM 层定义的业务上下文
        pool: StackPool(StackSlot(T), MAX_CONNECTIONS),

        const MAX_CONNECTIONS = 1_048_576;

        const StackSlot = struct {
            header: SlotHeader,      // gen_id + buf_recycled
            conn: Connection,        // swas 内核层：fd, state, write_offset...
            user: T,                 // IM 业务层：user_id, room_id, device_type...
            prev_live: u32,          // 双向链表：上一个活跃连接
            next_live: u32,          // 双向链表：下一个活跃连接
        };

        fn onReadComplete(self: *Self, cqe: ...) void {
            const idx = unpackIdx(cqe.user_data);
            const slot = &self.pool.slots[idx];
            if (unpackGenId(cqe.user_data) != slot.header.gen_id) return;

            // 用 slot.conn 代替当前 conn 的所有字段
            // 用 slot.user 代替 ctx.app_ctx 的业务查询
        }
    };
}
```

### 迁移步骤

1. `Connection` 保持不变，`StackSlot` 嵌入 `Connection`
2. `user_data` 从 `conn_id` 切到 `packUserData(gen_id, idx)`
3. `AutoHashMap` 逐步替换为 `StackPool.slots[idx]` 直接索引
4. IM 层 `AppContext` 字段收敛到 `T`（`StackSlot.user`）
5. `checkIdleConnections` 利用 `prev_live → next_live` 链表遍历，不扫 1M 空位

### app_ctx 消失

当前 `app_ctx: ?*anyopaque` 挂在 AsyncServer 上，每个请求从 `ctx.app_ctx` 拿。切到 StackPool 后：

```zig
// 旧：通过 app_ctx 指针跳转，cache miss
const app = @as(*AppContext, @ptrCast(@alignCast(ctx.server.?.app_ctx)));

// 新：slot 就在手边，user 字段紧挨 conn，一次 cache line 全带走
const slot = &server.pool.slots[conn_idx];
const user_id = slot.user.user_id;
const nats_client = slot.user.nats;
```

---

## 7. 深水区 Bug 排查（代码现状对照）

### 7.1 MULTISHOT_ACCEPT FD 孤儿化 — ❌ 当前不适用

**网页版推演**：MULTISHOT 模式下内核连续塞 CQE，若 StackPool 满漏掉 CQE，FD 变僵尸。

**代码现状**：`submitAccept` 使用 `ring.accept()` 是**单次 Accept**。每个 accept CQE 处理后手动 `submitAccept()` 再发下一个。

```zig
fn submitAccept(self: *Self) !void {
    _ = try self.ring.accept(ACCEPT_USER_DATA, ...);
}
```

不是 MULTISHOT，不存在批量 CQE 积压问题。StackPool 满时 `onAcceptComplete` 会 `close(fd)` 并 `submitAccept()` 继续。

**结论**：不适用。

---

### 7.2 Slab Buffer 静默污染 — ✅ 已防御

**推演**：连接 A 的 Slab Buffer 在 write 重试期间被回收，连接 B 数据写入 A 的 buffer → 串号。

**代码现状**：
- 读缓冲（provided buffer）和写缓冲（tiered pool）**完全隔离**，从不混用。
- 读缓冲回收路径：`httpTaskComplete` / `.closing` CQE handler，均有 `buf_recycled` 守卫。
- 写缓冲回收路径：`closeConn` 第二遍（close CQE 回包后），同样有 `buf_recycled` 守卫。
- `IORING_OP_CLOSE` 保证排序：write SQE 全部完成 → close CQE → 才 free 写缓冲。

**结论**：已防御。读/写缓冲物理隔离 + `buf_recycled` 单次回收 + ring 排序。

---

### 7.3 last_active_ms 全量扫描 — ⚠️ 待优化

**推演**：1M 连接下 `for (conns)` 遍历 400MB → L3 Cache Miss。

**代码现状**：`checkIdleConnections` 用 `connections.iterator()` 遍历全部 HashMap 条目。

```zig
var it = self.connections.iterator();
while (it.next()) |entry| {
    const conn = entry.value_ptr;
    if (conn.state == .reading and ...) to_remove.append(...);
}
```

**影响**：HashMap 遍历本身 O(n)，加上 Cache Miss。1M 连接下每次 TTL 扫描约 400MB 内存访问。

**优化方向**：
- StackPool 增加 `u64` BitSet，每 64 个连接一组。只有活跃组才扫描。
- 双向链表 `prev_live → next_live` 串联活跃连接，不扫空位。
- TTL 扫描也从 30s 拉到 60s，减少频率。

**结论**：当前 HashMap 遍历可工作，但 1M 量级下是性能瓶颈。StackPool 的链表/BitSet 方案已设计，待实现。

---

### 7.4 StackPool Cache-Line 友好布局

**设计**：每 slot 400 字节，按 64B cache line 切分热/冷字段。

```
Offset   0- 63 (Line 1): fd, gen_id, state, write_offset, write_retries, buf_recycled
                        ↑ IO 循环最热路径

Offset  64-127 (Line 2): user_id, room_id, last_active_ms, prev_live, next_live
                        ↑ 业务层 + TTL 扫描

Offset 128-191 (Line 3): ws_token, read_bid, write_iovs
                        ↑ WebSocket + 写重试

Offset 192-399 (Line 4-6): 业务扩展区（IM 自定义字段）
                        ↑ 低频访问，不占 L1
```

**收益**：短写重试时 CPU 只需加载 Line 1（64B），不碰后面的用户 ID/房间 ID。主循环每轮处理 N 个连接时，活跃数据全部挤在 L1/L2。

```zig
const StackSlot = struct {
    // ── Line 1 (hot) ──
    gen_id: u32,
    state: u8,
    buf_recycled: bool,
    write_retries: u8,
    _pad1: u16,
    fd: i32,
    write_offset: u32,
    write_headers_len: u32,
    // ... fill to 64 bytes

    // ── Line 2 (warm) ──
    user_id: u64,
    last_active_ms: i64,
    prev_live: u32,
    next_live: u32,
    // ... fill to 64 bytes

    // ── Line 3+ (cold) ──
    // 业务扩展 ...
};
```
