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
- `Next.submit()` — 线程池。**仅用于 CPU 密集型计算**，避免阻塞。

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

用于 CPU 重活（加解密、压缩、LLM 推理）：

```zig
const Ctx = struct { allocator: Allocator, resp: *DeferredResponse };

fn exec(c: *Ctx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);
    // CPU 重活在这里做...
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
- `1` — 默认，加解密、压缩够用
- `N/2`（8 核设 4）— 仅持续 LLM CPU 推理时才需要
- GPU 推理：worker 数量无关（计算在 GPU）

### DeferredResponse

从任意线程发 HTTP 响应（CAS 无锁链表推送到 IO 线程）：

```zig
resp.json(200, "{\"ok\":true}");
resp.text(200, "plain");
```

### Deferred 钩子

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

### Next.go / Next.submit

```zig
Next.go(Ctx, ctx, exec);       // IO 线程 fiber（io_uring I/O）
Next.submit(Ctx, ctx, exec);   // 线程池（CPU 重活）
```

都是静态方法。`Next.go` 开箱即用（首次路由自动 `setDefault`）。`Next.submit` 需要 `server.initPool4NextSubmit(n)`。

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
