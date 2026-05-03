# swas — Single Worker Async Server

[中文文档](README_CN.md)

A single-thread async HTTP + WebSocket server on Linux `io_uring`, in Zig 0.16.0.

```
IO thread (io_uring + fiber):
  ├── accept/read/write CQE → fiber → handler → respond
  ├── drain user SubmitQueues
  ├── drain Next.go() ringbuffer tasks
  └── drain DeferredResponse → respond

Worker pool (optional, CPU-heavy only):
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
git clone https://github.com/fndome/swas
cd swas
zig build run
```

## Use as a Library

```zig
const swas = @import("swas");

pub fn main() !void {
    var server = try swas.AsyncServer.init(alloc, io, "0.0.0.0:9090", null, 64);
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

For CPU-heavy work (crypto, compression, LLM inference):

```zig
const Ctx = struct { allocator: Allocator, resp: *DeferredResponse };

fn exec(c: *Ctx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);
    // CPU-heavy work here...
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
- `N/2` (e.g. 4 on 8-core) — sustained LLM CPU inference
- GPU inference: worker count irrelevant (GPU handles compute)

### DeferredResponse

Sends HTTP response from any thread (CAS-based lock-free):

```zig
resp.json(200, "{\"ok\":true}");
resp.text(200, "plain");
```

### Deferred Hooks

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

Rooms with countdown → auto-battle for hundreds of players. Hook checks deadline, copies data,
then `Next.submit` runs CPU-heavy battle on worker threads. Zero locks — all state on IO thread.

```zig
const Room = struct {
    id: u64,
    state: enum { waiting, fighting, settle },
    deadline: i64,                  // monotonic timestamp
    teams: [2]std.ArrayList(*Player),
};

const Player = struct {
    id: u64,
    hp: u32,
    atk: u32,
};

const BattleCtx = struct {
    // copied from room before submit (lightweight, no deep-clone)
    blue_team: []PlayerSnapshot,
    red_team:  []PlayerSnapshot,
};

const PlayerSnapshot = struct { hp: u32, atk: u32 };
```

```zig
fn roomHook(server: *AsyncServer, node: *DeferredNode) void {
    const app: *GameApp = @ptrCast(@alignCast(server.app_ctx.?));
    // node.body = player command (join / ready / action)
    app.processCommand(node.body);

    for (app.rooms.items) |*room| {
        if (room.state == .waiting and server.monotonic_ms() >= room.deadline) {
            room.state = .fighting;
            startBattle(server, room);
        }
    }
}

fn startBattle(server: *AsyncServer, room: *Room) void {
    const ctx = server.allocator.create(BattleCtx) catch return;
    ctx.blue_team = snapshotTeam(&room.teams[0], server.allocator) catch return;
    ctx.red_team  = snapshotTeam(&room.teams[1], server.allocator) catch return;
    Next.submit(BattleCtx, ctx, doBattle);
}

fn doBattle(ctx: *BattleCtx, complete: *const fn (?*anyopaque, []const u8) void) void {
    // heavy combat calc — safe on worker thread
    const result = simulateCombat(ctx.blue_team, ctx.red_team);

    var buf: [4096]u8 = undefined;
    const json = result.toJson(&buf);

    // push result back to IO thread — lock-free
    server.sendDeferredResponse(room_id, 200, .json, json);
    _ = complete;
}

try server.addHookDeferred(roomHook);
```

### Next.go / Next.submit

```zig
Next.go(Ctx, ctx, exec);       // fiber on IO thread (io_uring I/O)
Next.submit(Ctx, ctx, exec);   // worker pool (CPU-heavy)
```

Both are static. `Next.go` works out of the box (auto `setDefault` on first route). `Next.submit` requires `server.initPool4NextSubmit(n)`.

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
> SWAS uses a **shared stack** (one 64KB buffer, all fibers reuse it). When a fiber
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
> SWAS chooses the latter. All async is done via `Next.go`/`Next.submit` with callbacks
> instead of `await`-style suspension.
> - Fibers are cooperative; OS threads are preemptive. This breaks the fiber model.
>
> | Zig pattern | SWAS replacement |
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
