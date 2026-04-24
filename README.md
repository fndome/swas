# swas — Single Worker Async Server

[中文文档](README_CN.md)

A single-threaded async HTTP + WebSocket server built on Linux `io_uring`, written in Zig 0.16.0.

## Design

- **Single-threaded event loop** — no locks, no context switch overhead
- **io_uring** — zero-copy syscalls, minimal user/kernel transitions
- **Zero-copy responses** — response body goes directly from handler to write queue, no intermediate buffering
- **Buffer Pool** — pre-allocated read/write buffer pool, zero allocation at runtime

## Requirements

- **Linux 5.1+** (io_uring required; Windows/macOS not supported)
- Zig 0.16.0
- Compiles and runs on Linux only. **Cannot compile on Windows** — the Zig std lib `linux.IoUring` module only defines full types for Linux targets.

## Quick Start

```bash
git clone https://github.com/fndome/swas
cd swas
zig build run
```

Server listens at `http://0.0.0.0:9090`.

## Use as a Library

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .swas = .{
        .url = "https://github.com/fndome/swas/archive/refs/tags/0.0.1.tar.gz",
        .hash = "1220...",
    },
},
```

Import in `build.zig`:

```zig
const swas_dep = b.dependency("swas", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("swas", swas_dep.module("swas"));
```

Use in code:

```zig
const swas = @import("swas");

pub fn main() !void {
    var io_backend = std.Io.Threaded.init(alloc, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var server = try swas.AsyncServer.init(alloc, io, "0.0.0.0:9090", null);
    defer server.deinit();

    server.GET("/hello", myHandler);
    try server.run();
}
```

## API

### Routing

```zig
try server.GET("/hello", helloHandler);
try server.POST("/data", postHandler);
try server.PUT("/resource", putHandler);
try server.PATCH("/resource", patchHandler);
try server.DELETE("/resource", delHandler);
```

Route key = `"METHOD:/path"`. Re-registering the same path with `GET`/`PUT` etc. is idempotent (overwrites).

### Middleware

```zig
// Global middleware (matches all paths)
try server.use("/**", logMiddleware);

// Exact path middleware
try server.use("/admin", authMiddleware);

// AntPath wildcard
try server.use("/api/**/user", apiMiddleware);

// Response middleware (runs synchronously on main thread, intercepts response)
try server.useThenRespondImmediately("/antpath-verify", jwtMiddleware);
```

Signature:
```zig
fn myMiddleware(allocator: Allocator, ctx: *Context) anyerror!bool;
// return true  → short-circuit, stop further middleware/handlers
// return false → continue
```

### WebSocket

```zig
fn wsHandler(conn_id: u64, frame: *const Frame, ws: *WsServer) void {
    if (frame.opcode == .text or frame.opcode == .binary) {
        ws.sendWsFrame(conn_id, frame.opcode, frame.payload);
    }
}

try server.ws("/echo", wsHandler);
```

Frame types: `text`, `binary`, `close`, `ping`, `pong`.

### Context

```zig
// Read request header
const token = ctx.getHeader("Authorization");

// Write response header
try ctx.setHeader("X-Request-Id", "abc-123");

// Response types
try ctx.text(200, "plain text");
try ctx.json(200, .{ .message = "hello" });
try ctx.html(200, "<h1>hello</h1>");
try ctx.rawJson(200, `{"raw": true}`);
```

`getHeader` is case-insensitive, returns `?[]const u8`.

### Configuration

All parameters via `server.config(key, value)`, defaults from `src/constants.zig`:

```zig
server.config(.idle_timeout_ms, 30000);       // idle timeout 30s
server.config(.buffer_size, 131072);           // buffer size 128KB
server.config(.buffer_pool_size, 4096);        // pool count
server.config(.ring_entries, 4096);            // io_uring queue depth
server.config(.task_queue_size, 2048);         // task queue capacity
server.config(.max_cqes_batch, 128);           // max completion events per batch
server.config(.max_path_length, 4096);         // max URL path length
```

| key | type | default | description |
|-----|------|---------|-------------|
| `max_header_buffer_size` | i32 | 8192 | max header bytes |
| `max_response_buffer_size` | i32 | 4096 | max response header bytes |
| `max_cqes_batch` | i32 | 64 | io_uring CQE batch size |
| `ring_entries` | i32 | 2048 | io_uring queue depth |
| `task_queue_size` | i32 | 1024 | worker task queue |
| `response_queue_size` | i32 | 1024 | response queue |
| `buffer_size` | i32 | 65536 | per-buffer size |
| `buffer_pool_size` | i32 | 2048 | buffer pool count |
| `write_buf_count` | i32 | 256 | write buffer count |
| `max_fixed_files` | i32 | 2048 | fixed file descriptors |
| `max_path_length` | i32 | 2048 | max URL path length |
| `idle_timeout_ms` | i32 | 60000 | idle connection timeout (ms) |

Some parameters (`ring_entries`, `buffer_pool_size`, etc.) take effect at `init()` time; `.config()` changes apply on next restart.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Main Thread                       │
│  io_uring event loop                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Accept   │  │ Read     │  │ Write             │  │
│  │ CQE →    │  │ CQE →    │  │ CQE →             │  │
│  │ new conn │  │ parse    │  │ keep-alive/close  │  │
│  └──────────┘  └────┬─────┘  └───────────────────┘  │
│                     │                                 │
│              ┌──────▼──────┐                          │
│              │  Worker      │  SPSC RingBuffer         │
│              │  Thread     │◄──── Task Queue          │
│              │             │──── Response Queue ──►   │
│              │  middleware │                          │
│              │  handler    │                          │
│              └─────────────┘                          │
└─────────────────────────────────────────────────────┘
```
