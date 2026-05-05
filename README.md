# sws — Single Worker Server

[中文文档](README_CN.md)

A single-thread async HTTP + WebSocket server on Linux `io_uring`, in Zig 0.16.0.

```
IO thread (io_uring + fiber):
  ├── accept/read/write CQE → fiber → handler → respond
  ├── drain user SubmitQueues
  ├── drain Next.go() ringbuffer tasks
  └── drain DeferredResponse → respond

Worker pool (optional, offload CPU/GPU/blocking I/O):
  └── Next.submit() → worker thread → compute → DeferredResponse → IO thread drains
```

Handlers run as **fibers on the IO thread** by default.
- `Next.go()` — fiber on IO thread, zero thread switch. Use for DB io_uring, async I/O.
- `Next.submit()` — worker pool. Use **only for CPU-intensive computation** that would block.

## Requirements

- Linux 5.1+ (io_uring)
- Zig 0.16.0

## Quick Start

```bash
git clone https://github.com/fndome/sws
cd sws
zig build run
```

## Use as a Library

```zig
const sws = @import("sws");

pub fn main() !void {
    var server = try sws.AsyncServer.init(alloc, io, "0.0.0.0:9090", null, 64);
    defer server.deinit();

    server.GET("/hello", myHandler);
    try server.run();
}
```

## Architecture

### Single IO thread + fiber

The entire event loop runs on **one IO thread**. Handlers execute as **fibers** (user-space coroutines) on the same thread.

```
IO thread (single):
  io_uring.submit_and_wait(1)
    → CQE dispatch
    → fiber → handler → ctx.text/json/html
    → drainNextTasks (Next.go ringbuffer tasks)
    → drainDeferred  (DeferredResponse)
    → loop
```

No background threads unless you call `server.initPool4NextSubmit(n)`.

### Init

```zig
var server = try AsyncServer.init(alloc, io, "0.0.0.0:9090", app_ctx, fiber_stack_size_kb);
//                                                                         ↑ 0 = 64KB
```

First handler/middleware registration calls `ensureNext()` → creates `Next` (ringbuffer) + `setDefault()`.

### Handler — Synchronous (on IO thread)

```zig
fn hello(allocator: Allocator, ctx: *Context) anyerror!void {
    ctx.text(200, "hello");
}
```

### Handler — `Next.go` (fiber, IO thread, no thread switch)

For async I/O (DB io_uring, HTTP client):

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

### Handler — `Next.submit` (worker pool, thread switch)

For offload work (crypto, compression, LLM/GPU inference, blocking I/O):

```zig
const Ctx = struct { allocator: Allocator, resp: *DeferredResponse };

fn exec(c: *Ctx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);
    // Offload work here (CPU/GPU/blocking I/O)...
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

### Worker pool (for Next.submit)

```zig
try server.initPool4NextSubmit(1); // 1 worker thread (recommended)
```

**Recommendations:**
- `1` — default, sufficient for crypto, compression
- `N/2` (e.g. 4 on 8-core) — sustained LLM/GPU inference or blocking I/O

### DeferredResponse

Sends HTTP response from any thread (CAS-based lock-free):

```zig
resp.json(200, "{\"ok\":true}");
resp.text(200, "plain");
```

### Deferred Hooks, Tick Hooks

Execute custom logic before each deferred response is sent, on the IO thread.
Essential for MMORPG / real-time use cases (update game state, leaderboard, broadcast):

```zig
fn updateGameState(server: *AsyncServer, node: *DeferredNode) void {
    const world: *GameWorld = @ptrCast(@alignCast(server.app_ctx.?));
    world.update(node.body);
}

try server.addHookDeferred(updateGameState);
```

**Rules:**
- Hooks run in registration order on the IO thread — safe for IO-thread-exclusive data
- `node.body` is valid during hook execution; do NOT free it
- Do NOT store `node` pointer — the node is destroyed after the hook returns
- Must not panic (log errors instead)

#### Room Auto-Battle Example

Rooms with countdown → auto-battle for hundreds of players. Two hooks cooperate:
`addHookTick` checks deadlines every loop iteration (no deferred node needed);
`addHookDeferred` processes incoming player commands.
Battle CPU work offloaded via `Next.submit`. Zero locks — all state on IO thread.

```zig
const Room = struct {
    id: u64,
    state: enum { waiting, fighting, settle },
    deadline: i64,                  // monotonic timestamp
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
    app.processCommand(node.body);  // join / ready / action
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

try server.addHookTick(roomTick);        // tick: fires every IO loop
try server.addHookDeferred(roomCommand); // deferred: fires per-player command
```

### Next.go / Next.submit

```zig
Next.go(Ctx, ctx, exec);       // fiber on IO thread (io_uring I/O)
Next.submit(Ctx, ctx, exec);   // worker pool (offload work)
```

Both are static. `Next.go` works out of the box (auto `setDefault` on first route). `Next.submit` requires `server.initPool4NextSubmit(n)`.

#### GPU / Heavy Compute

GPU compute uses `Next.submit` — worker thread calls CUDA / CANN / Vulkan runtime.
io_uring direct dispatch for GPU is blocked on Linux kernel drivers (missing
`IORING_OP_URING_CMD` for compute queues, NVIDIA / Huawei not yet shipped).

Once drivers add it, `IORegistry` handles GPU with zero code changes —
same `register(id, ptr, on_cqe)` → submit SQE → dispatch CQE pattern.

**Current: fiber + worker pool**

Worker pool always supports fiber. GPU task calls `Fiber.workerYield(poll, ctx)`
after submitting a kernel, freeing the worker thread to process other tasks while
the GPU runs. The worker tick polls parked fibers and resumes when the kernel completes.

```zig
// CPU task — no yield, runs to completion
Next.submit(CpuCtx, ctx, struct {
    fn exec(c: *CpuCtx, complete: ...) void {
        const result = heavyCompute(c.input);
        complete(c, result);
    }
}.exec);

// GPU task — MUST call workerYield after submitting kernel
//                                 ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
Next.submit(GpuCtx, ctx, struct {
    fn exec(c: *GpuCtx, complete: ...) void {
        cudaLaunchKernel(kernel, stream, args);
        Fiber.workerYield(            // ← THIS LINE makes it a GPU task
            struct { fn poll(s: *anyopaque) bool {
                return cuStreamQuery(@ptrCast(@alignCast(s))) == CUDA_SUCCESS;
            }}.poll,
            @ptrCast(stream),
        );
        // resume point — GPU done
        complete(c, output);
    }
}.exec);
```

**The only difference between CPU and GPU:** GPU tasks call `Fiber.workerYield`.
Without it, the worker thread blocks synchronously until the kernel completes,
defeating fiber multiplexing.

> ⚠️ **GPU tasks MUST use `Next.submit`, never `Next.go`.**
>
> `Next.go` runs on the IO thread. Two failure modes:
> - **Without `workerYield`:** `cuStreamSynchronize` blocks the IO thread —
>   io_uring CQE processing stops, entire server freezes.
> - **With `workerYield`:** fiber yields correctly, IO thread stays alive — but
>   the fiber never wakes up. The IO thread has no poll tick; it only responds to
>   io_uring CQEs. GPU kernels don't produce CQEs, so the IO thread never learns
>   the kernel finished.
>
> Worker threads have a built-in poll tick (`while poll_fn() try resume`) which
> is why GPU works there: `workerYield` → park → tick → poll → resume.

**IMPORTANT: GPU uses `initPool4NextSubmit(1)`.**
GPU drivers are async internally — one worker + fiber can submit N streams
and poll for completion. No extra thread pool needed. io_uring not yet
supported for GPU compute (kernel driver gap).

### RingSharedClient

io_uring-driven outbound TCP client. Glue layer for integrating NATS / Redis / HTTP client
libraries into sws's IO thread — no separate runtime, no locks.

```zig
const RingSharedClient = @import("sws").RingSharedClient;

fn onData(ctx: ?*anyopaque, data: []u8) void {
    const nats: *NatsClient = @ptrCast(@alignCast(ctx));
    nats.feed(data);
}

fn onClose(ctx: ?*anyopaque) void {
    const nats: *NatsClient = @ptrCast(@alignCast(ctx));
    nats.discard();
}

// In main(), before server.run():
var cs = try RingSharedClient.init(allocator, server.rs, onData, onClose, nats_ctx);
defer cs.deinit();
try cs.connect("127.0.0.1", 4222);

// Send data (queued, submitted via io_uring)
try cs.write("PUB subject 5\r\nhello\r\n");
cs.close();  // graceful
```

- All I/O on sws IO thread — `onData` / `onClose` run in the same context as hooks
- `write()` queues data; pending writes auto-flushed as io_uring CQEs arrive
- Protocol layer (NATS / Redis / HTTP) only needs `feed([]u8)` and `write([]const u8)`
- Multiple clients per server; user_data uses a dedicated high bit to avoid collisions

### Pipe

Adapts RingSharedClient's push model to a pull model (`reader.read` / `writer.write`).
Enables synchronous-protocol libraries (pgz, myzql) to run directly on the IO thread
via fiber yield/resume — no worker threads, no locks.

```zig
// In main(), after AsyncServer.init() and before server.run():
const Pipe = @import("sws").Pipe;
const RingSharedClient = @import("sws").RingSharedClient;

fn onData(ctx: ?*anyopaque, data: []u8) void {
    const p: *Pipe = @ptrCast(@alignCast(ctx));
    p.feed(data) catch {};
}

fn onClose(ctx: ?*anyopaque) void {
    const p: *Pipe = @ptrCast(@alignCast(ctx));
    p.reset();
}

var cs = try RingSharedClient.init(allocator, server.rs, onData, onClose, &pipe);
var pipe = try Pipe.init(allocator, cs);
defer pipe.deinit();

try cs.connect("localhost", 5432);
// ... wait for connect (yield) ...

// Any protocol lib with anytype reader/writer works:
// var conn = try pgz.Connection.init(allocator, pipe.reader(), pipe.writer());
// var result = try conn.query("SELECT 1", struct { u8 });
```

- `feed(data)` pushes bytes from ClientStream → read buffer, resumes waiting fiber
- `reader.read()` blocks the fiber (via yield) until data arrives — looks synchronous to caller
- `writer.write()` queues into buffer; `flushWrite()` sends via ClientStream
- `reset()` clears buffers on disconnect/reconnect
- Requires protocol library to accept `anytype` reader/writer (pgz needs 1-line patch on `WriteBuffer.send`)

### Fiber

Built-in fiber (x86_64 and ARM64 Linux). All handler fibers share a **single pre-allocated stack buffer** — sequential execution, no per-request stack allocation, zero contention.

> ⚠️ **Do NOT use `std.Io.async()` / `future.await()` in handlers.**
>
> Zig's `Future` is a **thread-based** design, not fiber-based:
> - `async()` → `std.Thread.spawn` + queued to OS thread pool (`Threaded.zig:2112`)
> - `await()` → `Thread.futexWait` — blocks the **OS thread** (`Threaded.zig:2436`)
>
> On the IO thread, blocking means:
> - io_uring CQE processing stops — no new connections, no reads, no writes
> - The entire server stalls for the duration of the work
>
> ### Why not patch the vtable to support Future on fibers?
>
> `future.await()` requires the caller's **stack frame to persist** across suspension:
> ```
> var future = io.async(work, .{data});
> const result = future.await(io);   // fiber yields here — stack must survive
> ctx.json(200, result);              // resumes here — expects data still intact
> ```
>
> SWS uses a **shared stack** (one 64KB buffer, all fibers reuse it). When a fiber
> yields in `await()`, the next fiber's execution overwrites that same memory. The
> resumed fiber's stack frame is corrupted.
>
> Switching to per-fiber stacks would fix this, but at a steep memory cost:
>
> | Concurrent requests | Per-fiber stack | Shared stack |
> |---|---:|---:|
> | 1K | 16 MB | 64 KB |
> | 20K | 320 MB | 64 KB |
> | 200K | 3.2 GB | 64 KB |
> | 1M | 16 GB | 64 KB |
>
> *(per-fiber stack at 16KB — the practical minimum for HTTP handlers)*
>
> At a typical production load of 200K concurrent requests, shared stack saves ~3GB.
> This directly translates to lower memory pressure and better operational stability.
>
> This is the fundamental tradeoff: **Future API semantics vs. 1M-connection memory model**.
> SWS chooses the latter. All async is done via `Next.go`/`Next.submit` with callbacks
> instead of `await`-style suspension.
> - Fibers are cooperative; OS threads are preemptive. This breaks the fiber model.
>
> | Zig pattern | SWS replacement |
> |---|---|
> | `io.async(cpuWork)` + `future.await(io)` | `Next.submit(Ctx, ctx, exec)` + `DeferredResponse` |
> | `io.async(ioWork)` + `future.await(io)` | `Next.go(Ctx, ctx, exec)` (fiber on IO thread) |
>
> **Pattern**:
> ```zig
> // ❌ Don't do this in handler — blocks IO thread:
> // var future = io.async(heavyWork, .{data});
> // const result = future.await(io);
>
> // ✅ Do this instead — IO thread never blocks:
> fn myHandler(allocator: Allocator, ctx: *Context) anyerror!void {
>     ctx.deferred = true;
>     const resp = try allocator.create(DeferredResponse);
>     resp.* = .{ .server = server, .conn_id = ctx.conn_id, .allocator = allocator };
>     Next.submit(Ctx, .{ .resp = resp, .data = data }, exec);
> }
> ```
>
> See `Next.submit` section above for the full exec/complete callback API.

### Routing / Middleware / WebSocket / Context

See `example/` and `src/example.zig`.

## Memory Model (1M connections target)

| Component | Size | Notes |
|-----------|------|-------|
| Connection struct | ~110 bytes | Per-connection state |
| Write buffer | 0 bytes idle | Lazily allocated from tiered pool (512B-64KB) |
| Read buffer | 0 bytes idle | io_uring provided buffers, returned on idle |
| Slab for io_uring reads | 64MB | 16384 × 4KB blocks, recycled by kernel |
| Tiered write pool | dynamic | 8 size classes, recycled |
| **1M idle connections** | **~250MB** | No per-thread stack overhead |

Like [greatws](https://github.com/antlabs/greatws), idle connections consume zero buffer memory.

### WebSocket payload copying

WS handlers may offload frame data asynchronously, so frame payloads must remain valid after handler returns. **WS frame payloads are always duped — never zero-copy.**

**Performance impact (100B text frame):**

| Operation | Cost | Notes |
|-----------|------|-------|
| memcpy(100B) | ~10ns | Copy frame payload |
| GeneralPurposeAllocator alloc/free | ~100ns | One alloc+free per frame |

**~110ns overhead per frame**. 1M connections, 1% active, 10 msg/s each = 100K msg/s:
- CPU: 100K × 110ns = **11ms/s = 1.1% of one core**

## Config

| key | default | description |
|-----|---------|-------------|
| `fiber_stack_size_kb` | 64 | fiber stack size (KB). 0 = 64 |
| `io_cpu` | null | pin IO thread to CPU core |
| `idle_timeout_ms` | 30000 | close idle connections |
| `buffer_size` | 4096 | io_uring buffer block size |
| `buffer_pool_size` | 16384 | number of buffer blocks |

## Advanced: io_uring-native DB Pool

Wire your DB driver's TCP fd into io_uring directly:

```
handler (fiber on IO thread):
  └── db.query(sql)
        └── io_uring write(fd, query) → CQE → io_uring read(fd) → CQE → parse
              → ctx.json(200, result)
```

For connection pooling: maintain a pool of connected TCP fds in a ringbuffer. Handler pops fd, issues `write(sql)` + `read()` via io_uring, parses result, pushes fd back.

## License

MIT
