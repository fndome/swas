# swas — 单线程异步服务器

基于 Linux `io_uring` 的单线程 HTTP + WebSocket 服务器，Zig 0.16.0。

```
IO 线程（io_uring + fiber）:
  ├── accept/read/write CQE → fiber → handler → 发响应
  ├── drain 用户 SubmitQueues
  ├── drain Next.go() ringbuffer 任务
  └── drain DeferredResponse → 发响应

Worker 线程池（可选，仅 CPU 密集任务）:
  └── Next.submit() → worker 线程 → 计算 → DeferredResponse → IO 线程 drain
```

Handler 默认作为 **fiber 运行在 IO 线程上**。
- `Next.go()` — IO 线程 fiber，零线程切换。用于 DB io_uring、异步 I/O。
- `Next.submit()` — 线程池。将 CPU 重活、GPU 推理、同步阻塞 I/O 卸离 IO 线程。

## 环境要求

- Linux 5.1+（io_uring）
- Zig 0.16.0

## 快速开始

```bash
git clone https://github.com/fndome/swas
cd swas
zig build run
```

## 作为库使用

```zig
const swas = @import("swas");

pub fn main() !void {
    var server = try swas.AsyncServer.init(alloc, io, "0.0.0.0:9090", null, 64);
    defer server.deinit();

    server.GET("/hello", myHandler);
    try server.run();
}
```

## 架构

### 单 IO 线程 + fiber

整个事件循环跑在**一个 IO 线程**上。Handler 作为 **fiber**（用户态协程）在同一线程中执行。

```
IO 线程（单线程）:
  io_uring.submit_and_wait(1)
    → CQE 分发
    → fiber → handler → ctx.text/json/html
    → drainNextTasks（Next.go ringbuffer 任务）
    → drainDeferred（DeferredResponse）
    → 循环
```

除非显式调用 `server.initPool4NextSubmit(n)`，不会启动任何后台线程。

### 初始化

```zig
var server = try AsyncServer.init(alloc, io, "0.0.0.0:9090", app_ctx, fiber_stack_size_kb);
//                                                                         ↑ 0 = 64KB
```

首次注册 handler/middleware 时 `ensureNext()` 自动创建 `Next`（ringbuffer）+ `setDefault()`。

### Handler — 同步（跑在 IO 线程）

```zig
fn hello(allocator: Allocator, ctx: *Context) anyerror!void {
    ctx.text(200, "hello");
}
```

### Handler — `Next.go`（fiber，IO 线程，不切线程）

用于异步 I/O（DB io_uring、HTTP Client 等）：

```zig
const Ctx = struct { allocator: Allocator, resp: *DeferredResponse };

fn exec(c: *Ctx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);
    c.resp.json(200, "[{\"id\":1}]");
    complete(c, "");
}

fn myHandler(allocator: Allocator, ctx: *Context) anyerror!void {
    const s: *AsyncServer = @ptrCast(@alignCast(ctx.server.?));
    const resp = try allocator.create(DeferredResponse);
    resp.* = .{ .server = s, .conn_id = ctx.conn_id, .allocator = allocator };
    ctx.deferred = true;
    Next.go(Ctx, .{ .allocator = allocator, .resp = resp }, exec);
}
```

### Handler — `Next.submit`（线程池，切线程）

用于卸货（加解密、压缩、LLM/GPU 推理、阻塞 I/O）：

```zig
const Ctx = struct { allocator: Allocator, resp: *DeferredResponse };

fn exec(c: *Ctx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);
    // 卸货逻辑放这里（CPU/GPU/阻塞 I/O）...
    c.resp.json(200, "{\"done\": true}");
    complete(c, "");
}

fn myHandler(allocator: Allocator, ctx: *Context) anyerror!void {
    const s: *AsyncServer = @ptrCast(@alignCast(ctx.server.?));
    const resp = try allocator.create(DeferredResponse);
    resp.* = .{ .server = s, .conn_id = ctx.conn_id, .allocator = allocator };
    ctx.deferred = true;
    Next.submit(Ctx, .{ .allocator = allocator, .resp = resp }, exec);
}
```

### Worker 线程池（Next.submit 用）

```zig
try server.initPool4NextSubmit(1); // 1 个 worker 线程（推荐）
```

**推荐配置：**
- `1` — 默认，加解密、压缩、CPU 推理够用
- `N/2`（8 核设 4）— 持续 CPU 推理或阻塞 I/O
- GPU 推理：`1` — 目前 GPU 不支持 io_uring，1 个 worker + fiber 即可复用 N 个并发任务

### DeferredResponse

从任意线程发 HTTP 响应（CAS 无锁链表推送到 IO 线程）：

```zig
resp.json(200, "{\"ok\":true}");
resp.text(200, "plain");
```

### Deferred 钩子、Tick 钩子

在每次延迟响应发送前执行自定义逻辑，跑在 IO 线程上。
MMORPG / 实时场景必需（更新游戏状态、排行榜、广播）：

```zig
fn updateGameState(server: *AsyncServer, node: *DeferredNode) void {
    const world: *GameWorld = @ptrCast(@alignCast(server.app_ctx.?));
    world.update(node.body);
}

try server.addHookDeferred(updateGameState);
```

**规则：**
- 按注册顺序在 IO 线程执行——可安全访问 IO 线程独占数据
- `node.body` 在钩子执行期间有效，**禁止释放**
- **禁止保存** `node` 指针——钩子返回后 node 被销毁
- 必须不能 panic（用 log 记录错误）

#### 房间自动战场示例

倒计时 → 自动开战，支持数百人混战。两个钩子协作：
`addHookTick` 每轮 IO 循环检查截止时间（无需 deferred 节点）；
`addHookDeferred` 处理玩家指令。
战斗 CPU 重活通过 `Next.submit` 卸到线程池。全程零锁——游戏状态都在 IO 线程。

```zig
const Room = struct {
    id: u64,
    state: enum { waiting, fighting, settle },
    deadline: i64,                  // 单调时间戳
    teams: [2]std.ArrayList(*Player),
};

const Player = struct { id: u64, hp: u32, atk: u32 };

const BattleCtx = struct {
    blue_team: []PlayerSnapshot,
    red_team:  []PlayerSnapshot,
};

const PlayerSnapshot = struct { hp: u32, atk: u32 };
```

```zig
fn roomTick(server: *AsyncServer) void {
    const app: *GameApp = @ptrCast(@alignCast(server.app_ctx.?));
    for (app.rooms.items) |*room| {
        if (room.state == .waiting and server.monotonic_ms() >= room.deadline) {
            room.state = .fighting;
            startBattle(server, room);
        }
    }
}

fn roomCommand(server: *AsyncServer, node: *DeferredNode) void {
    const app: *GameApp = @ptrCast(@alignCast(server.app_ctx.?));
    app.processCommand(node.body);  // 进房 / 准备 / 操作
}

fn startBattle(server: *AsyncServer, room: *Room) void {
    const ctx = server.allocator.create(BattleCtx) catch return;
    ctx.blue_team = snapshotTeam(&room.teams[0], server.allocator) catch return;
    ctx.red_team  = snapshotTeam(&room.teams[1], server.allocator) catch return;
    Next.submit(BattleCtx, ctx, doBattle);
}

fn doBattle(ctx: *BattleCtx, complete: *const fn (?*anyopaque, []const u8) void) void {
    const result = simulateCombat(ctx.blue_team, ctx.red_team);
    var buf: [4096]u8 = undefined;
    const json = result.toJson(&buf);
    server.sendDeferredResponse(room_id, 200, .json, json);
    _ = complete;
}

try server.addHookTick(roomTick);        // tick: 每轮 IO 循环必触发
try server.addHookDeferred(roomCommand); // deferred: 每条玩家指令触发一次
```

### Next.go / Next.submit

```zig
Next.go(Ctx, ctx, exec);       // IO 线程 fiber（io_uring I/O）
Next.submit(Ctx, ctx, exec);   // 线程池（卸货）
```

都是静态方法。`Next.go` 开箱即用（首次路由自动 `setDefault`）。`Next.submit` 需要 `server.initPool4NextSubmit(n)`。

#### GPU / 重型计算

GPU 计算用 `Next.submit` — worker 线程调 CUDA / CANN / Vulkan runtime。
io_uring 直连 GPU 受限于 Linux 内核驱动（compute queue 尚未接 `IORING_OP_URING_CMD`，
NVIDIA / 华为还未发布）。

一旦驱动支持，`IORegistry` 零改动接管 GPU — 同一份 `register(id, ptr, on_cqe)` →
提交 SQE → CQE 回调模式。

**当前：fiber + worker 池**

Worker 池始终支持 fiber。GPU 任务提交 kernel 后调 `Fiber.workerYield(poll, ctx)`
释放 worker 线程去处理其他任务，GPU 在后台计算。worker tick 轮询 parked fiber，
kernel 完成后自动 resume。

```zig
// CPU 任务 — 不 yield，跑到结束
Next.submit(CpuCtx, ctx, struct {
    fn exec(c: *CpuCtx, complete: ...) void {
        const result = heavyCompute(c.input);
        complete(c, result);
    }
}.exec);

// GPU 任务 — 提交 kernel 后必须调 workerYield
//                              ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
Next.submit(GpuCtx, ctx, struct {
    fn exec(c: *GpuCtx, complete: ...) void {
        cudaLaunchKernel(kernel, stream, args);
        Fiber.workerYield(            // ← 这一行决定它是 GPU 任务
            struct { fn poll(s: *anyopaque) bool {
                return cuStreamQuery(@ptrCast(@alignCast(s))) == CUDA_SUCCESS;
            }}.poll,
            @ptrCast(stream),
        );
        // resume 点 — GPU 计算完成
        complete(c, output);
    }
}.exec);
```

**CPU 与 GPU 的唯一区别：** GPU 任务调 `Fiber.workerYield`。
不调这行 = worker 线程同步阻塞等 kernel 结束 = fiber 复用失效。

> ⚠️ **GPU 任务只能用 `Next.submit`，禁止用 `Next.go`。**
>
> `Next.go` 跑在 IO 线程。两种死法：
> - **不调 `workerYield`：** `cuStreamSynchronize` 同步阻塞 IO 线程 —
>   io_uring CQE 停摆，整个服务器冻结。
> - **调了 `workerYield`：** fiber 正常挂起，IO 线程继续跑 — 但 fiber 永远不醒。
>   IO 线程没有 poll tick，只响应 io_uring CQE。GPU kernel 不产生 CQE，
>   所以 IO 线程永远不会知道 kernel 完成了。
>
> Worker 线程有内置 poll tick（`while poll_fn() try resume`），GPU 能工作正是
> 因为这个：`workerYield` → park → tick → poll → resume。

**注意：GPU 推理用 `initPool4NextSubmit(1)`。**
GPU 驱动内置异步执行，1 个 worker + fiber 即可提交 N 个 stream 并轮询完成，
无需额外线程池。

### ClientStream

基于 io_uring 的出站 TCP 客户端胶水层。用于将 NATS / Redis / HTTP client 等第三方库集成到 swas 的 IO 线程——无需独立运行时，全程零锁。

```zig
const ClientStream = @import("swas").ClientStream;

fn onData(ctx: ?*anyopaque, data: []u8) void {
    const nats: *NatsClient = @ptrCast(@alignCast(ctx));
    nats.feed(data);
}

fn onClose(ctx: ?*anyopaque) void {
    const nats: *NatsClient = @ptrCast(@alignCast(ctx));
    nats.discard();
}

// 在 main() 里，server.run() 之前：
var cs = try ClientStream.init(allocator, &server.ring, &server.io_registry, onData, onClose, nats_ctx);
defer cs.deinit();
try cs.connect("127.0.0.1", 4222);

// 发送数据（排队，经由 io_uring 异步发送）
try cs.write("PUB subject 5\r\nhello\r\n");
cs.close();  // 优雅关闭
```

- 所有 I/O 跑在 swas IO 线程 — `onData` / `onClose` 与 hook 在同一上下文执行
- `write()` 排队发送；待发数据在 io_uring CQE 到达时自动冲刷
- 协议层（NATS / Redis / HTTP）只需实现 `feed([]u8)` 和 `write([]const u8)`
- 支持多个 client 实例；user_data 用专属高位 bit 避免碰撞

### Pipe

将 ClientStream 的推模型适配为拉模型（`reader.read` / `writer.write`）。
使同步风格的协议库（pgz、myzql）通过 fiber yield/resume 直接跑在 IO 线程——
无需 worker 线程，全程零锁。

```zig
// 在 main() 里，AsyncServer.init() 之后、server.run() 之前：
const Pipe = @import("swas").Pipe;
const ClientStream = @import("swas").ClientStream;

fn onData(ctx: ?*anyopaque, data: []u8) void {
    const p: *Pipe = @ptrCast(@alignCast(ctx));
    p.feed(data) catch {};
}

fn onClose(ctx: ?*anyopaque) void {
    const p: *Pipe = @ptrCast(@alignCast(ctx));
    p.reset();
}

var cs = try ClientStream.init(allocator, &server.ring, &server.io_registry, onData, onClose, &pipe);
var pipe = try Pipe.init(allocator, cs);
defer pipe.deinit();

try cs.connect("localhost", 5432);
// ... wait for connect (yield) ...

// 任何接受 anytype reader/writer 的协议库直接可用：
// var conn = try pgz.Connection.init(allocator, pipe.reader(), pipe.writer());
// var result = try conn.query("SELECT 1", struct { u8 });
```

- `feed(data)` 将 ClientStream 字节推入读缓冲区，唤醒等待中的 fiber
- `reader.read()` 在无数据时通过 fiber yield 挂起——对调用方表现为同步阻塞
- `writer.write()` 写入缓冲区；`flushWrite()` 通过 ClientStream 发出
- `reset()` 在断开/重连时清空缓冲区
- 要求协议库接受 `anytype` reader/writer（pgz 需改 `WriteBuffer.send` 一行）

### Fiber

swas 内置极简 fiber（x86_64 + ARM64 Linux）。所有 handler fiber **共享一块预分配栈**——顺序执行，无 per-request 分配，零竞争。

> ⚠️ **严禁在 handler 中使用 `std.Io.async()` / `future.await()`。**
>
> Zig 的 `Future` 是**基于线程（thread）设计**，而非基于 fiber：
> - `async()` → `std.Thread.spawn` + 投入 OS 线程池 (`Threaded.zig:2112`)
> - `await()` → `Thread.futexWait` — 阻塞 **OS 线程** (`Threaded.zig:2436`)
>
> 在 IO 线程上阻塞意味着：
> - io_uring CQE 处理停摆——不接收新连接、不读写
> - 整个服务器卡死
>
> ### 为什么不能 patch vtable 让 Future 跑在 fiber 上？
>
> `future.await()` 要求调用者的**栈帧在暂停期间保持存活**：
> ```
> var future = io.async(work, .{data});
> const result = future.await(io);   // fiber 在此 yield — 栈必须保留
> ctx.json(200, result);              // 在此恢复 — 依赖栈上数据
> ```
>
> SWAS 使用**共享栈**（一块 64KB buffer，所有 fiber 复用）。当 fiber 在 `await()`
> 中 yield，下一个 fiber 的执行会覆盖同一块内存。恢复后的 fiber 栈帧已损坏。
>
> 换成 per-fiber 独立栈可以解决，但内存代价巨大：
>
> | 并发请求数 | 独立栈 | 共享栈 |
> |---|---:|---:|
> | 1K | 16 MB | 64 KB |
> | 2 万 | 320 MB | 64 KB |
> | 20 万 | 3.2 GB | 64 KB |
> | 100 万 | 16 GB | 64 KB |
>
> *(独立栈按 16KB 计算，HTTP handler 的最低可行值)*
>
> 按生产环境常见的 20 万并发计算，共享栈节省约 3GB 内存。
> 更小的内存占用直接提升系统稳定性和运维可靠性。
>
> 这就是根本取舍：**Future API 的语义 vs. 百万连接的内存模型**。
> SWAS 选择了后者。所有异步通过 `Next.go`/`Next.submit` + 回调完成，而非 `await` 式暂停恢复。
> - fiber 是协作式切换，OS 线程是抢占式调度。两者互不兼容。
>
> | Zig 模式 | swas 替代 |
> |---|---|
> | `io.async(cpuWork)` + `future.await(io)` | `Next.submit(Ctx, ctx, exec)` + `DeferredResponse` |
> | `io.async(ioWork)` + `future.await(io)` | `Next.go(Ctx, ctx, exec)`（IO 线程 fiber）|
>
> **用法**：
> ```zig
> // ❌ 不要在 handler 里这样做——阻塞 IO 线程：
> // var future = io.async(heavyWork, .{data});
> // const result = future.await(io);
>
> // ✅ 应该这样——IO 线程永不阻塞：
> fn myHandler(allocator: Allocator, ctx: *Context) anyerror!void {
>     ctx.deferred = true;
>     const resp = try allocator.create(DeferredResponse);
>     resp.* = .{ .server = server, .conn_id = ctx.conn_id, .allocator = allocator };
>     Next.submit(Ctx, .{ .resp = resp, .data = data }, exec);
> }
> ```
>
> 完整 API 见上方 `Next.submit` 章节。

### 路由 / 中间件 / WebSocket / Context

见 `example/` 和 `src/example.zig`。

## 内存模型（目标百万连接）

| 组件 | 大小 | 说明 |
|------|------|------|
| 连接结构体 | ~110 字节 | 每连接状态 |
| 写缓冲区 | 空闲时 0 字节 | 从分层池按需分配（512B-64KB） |
| 读缓冲区 | 空闲时 0 字节 | io_uring 提供缓冲区，空闲时归还 |
| io_uring 读缓冲 slab | 64MB | 16384 × 4KB 块，内核回收 |
| 分层写缓冲池 | 动态 | 8 个尺寸类别，循环复用 |
| **100 万空闲连接** | **~250MB** | 无线程栈开销 |

和 [greatws](https://github.com/antlabs/greatws) 一样，空闲连接消耗零缓冲内存。

### WebSocket 帧负载拷贝

WS handler 可将帧数据异步卸出，因此帧负载在 handler 返回后仍需有效。**WS 帧负载永不做零拷贝优化**——始终 `dupe` 一份。

**性能影响（100 字节文本帧）：**

| 操作 | 耗时 | 说明 |
|------|------|------|
| memcpy(100B) | ~10ns | 拷贝帧负载 |
| GeneralPurposeAllocator alloc/free | ~100ns | 每帧一次分配释放 |

**每帧额外开销 ~110ns**。1M 连接、1% 活跃、每连接每秒 10 条消息 = 100K msg/s：
- CPU：100K × 110ns = **11ms/s = 1.1% 单核**

## 配置

| key | 默认值 | 说明 |
|-----|--------|------|
| `fiber_stack_size_kb` | 64 | fiber 栈大小（KB），0 自动变 64 |
| `io_cpu` | null | IO 线程绑核 |
| `idle_timeout_ms` | 30000 | 关闭空闲连接 |
| `buffer_size` | 4096 | io_uring 缓冲区块大小 |
| `buffer_pool_size` | 16384 | 缓冲区块数量 |

## 进阶：io_uring 原生 DB 连接池

直接把 DB driver 的 TCP fd 接入 io_uring：

```
handler（IO 线程上的 fiber）:
  └── db.query(sql)
        └── io_uring write(fd, query) → CQE → io_uring read(fd) → CQE → 解析
              → ctx.json(200, result)
```

连接池只需维护已连接 TCP fd 集合（ringbuffer 或 free list）。handler 拿 fd → io_uring 发 `write(sql)` + `read()` → 解析结果 → 放回 fd。

## License

MIT
