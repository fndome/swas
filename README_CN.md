# swas — Single Worker Async Server

基于 Linux `io_uring` 的单线程异步 HTTP + WebSocket 服务器，使用 Zig 0.16.0 编写。

## 设计理念

- **单线程事件循环**：避免锁竞争和上下文切换开销
- **io_uring**：零拷贝系统调用，减少用户态/内核态切换
- **零拷贝响应**：响应体直接从 handler 传递到写队列，无需中间缓冲
- **Buffer Pool**：预分配读写缓冲池，运行期零分配

## 要求

- **Linux 5.1+**（io_uring 必需，不支持 Windows/macOS）
- Zig 0.16.0
- 在 Linux 上直接编译运行。**Windows 上无法编译**——Zig 标准库的 `linux.IoUring` 模块仅对 Linux 目标有完整类型定义。

## 快速开始

```bash
git clone https://github.com/fndome/swas.git
cd swas
zig build run
```

服务器监听 `http://0.0.0.0:9090`。

## 作为库使用

在 `build.zig.zon` 添加依赖：

```zig
.dependencies = .{
    .swas = .{
        .url = "https://github.com/fndome/swas/archive/refs/tags/0.0.1.tar.gz",
        .hash = "1220...",
    },
},
```

在 `build.zig` 中导入模块：

```zig
const swas_dep = b.dependency("swas", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("swas", swas_dep.module("swas"));
```

在代码中使用：

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

### 路由注册

```zig
try server.GET("/hello", helloHandler);
try server.POST("/data", postHandler);
try server.PUT("/resource", putHandler);
try server.PATCH("/resource", patchHandler);
try server.DELETE("/resource", delHandler);
```

路由 key = `"METHOD:/path"`，`PUT` / `GET` 等多次注册同一路径幂等覆盖。

### 中间件

```zig
// 全局中间件（匹配所有路径）
try server.use("/**", logMiddleware);

// 精确路径中间件
try server.use("/admin", authMiddleware);

// AntPath 通配符匹配
try server.use("/api/**/user", apiMiddleware);

// 响应中间件（在主线程同步执行，拦截响应）
try server.useThenRespondImmediately("/antpath-verify", jwtMiddleware);
```

中间件签名：
```zig
fn myMiddleware(allocator: Allocator, ctx: *Context) anyerror!bool;
// return true  → 短路，停止后续中间件/handler
// return false → 继续传递
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

WebSocket 帧类型：`text`、`binary`、`close`、`ping`、`pong`。

### Context

```zig
// 读请求头
const token = ctx.getHeader("Authorization");

// 写响应头
try ctx.setHeader("X-Request-Id", "abc-123");

// 响应类型
try ctx.text(200, "plain text");
try ctx.json(200, .{ .message = "hello" });
try ctx.html(200, "<h1>hello</h1>");
try ctx.rawJson(200, `{"raw": true}`);
```

`getHeader` 大小写不敏感，返回 `?[]const u8`。

## 架构

```
┌─────────────────────────────────────────────────────┐
│                     Main Thread                      │
│  io_uring 事件循环                                    │
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

## 配置

所有参数通过 `server.config(key, value)` 设置，默认值来自 `src/constants.zig`：

```zig
server.config(.idle_timeout_ms, 30000);       // 空闲超时 30秒
server.config(.buffer_size, 131072);           // 缓冲大小 128KB
server.config(.buffer_pool_size, 4096);        // 缓冲池数量
server.config(.ring_entries, 4096);            // io_uring 队列深度
server.config(.task_queue_size, 2048);         // 任务队列容量
server.config(.max_cqes_batch, 128);           // 每次最大完成事件数
server.config(.max_path_length, 4096);         // 路径最大长度
```

完整可配项：

| key | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `max_header_buffer_size` | i32 | 8192 | 请求头最大字节 |
| `max_response_buffer_size` | i32 | 4096 | 响应头最大字节 |
| `max_cqes_batch` | i32 | 64 | io_uring CQE 批处理数 |
| `ring_entries` | i32 | 2048 | io_uring 队列深度 |
| `task_queue_size` | i32 | 1024 | 工作线程任务队列 |
| `response_queue_size` | i32 | 1024 | 响应队列 |
| `buffer_size` | i32 | 65536 | 每个缓冲大小 |
| `buffer_pool_size` | i32 | 2048 | 缓冲池总数 |
| `write_buf_count` | i32 | 256 | 写缓冲数量 |
| `max_fixed_files` | i32 | 2048 | 固定文件描述符数 |
| `max_path_length` | i32 | 2048 | URL 路径最大长度 |
| `idle_timeout_ms` | i32 | 60000 | 空闲连接超时（ms） |

部分参数（`ring_entries`、`buffer_pool_size` 等）在 `init()` 时生效，`config()` 修改后下次启动生效。
