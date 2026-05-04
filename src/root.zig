const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AsyncServer = @import("example.zig").AsyncServer;
pub const Connection = @import("example.zig").Connection;
pub const Context = @import("example.zig").Context;
pub const Middleware = @import("example.zig").Middleware;
pub const Handler = @import("example.zig").Handler;
pub const PathRule = @import("antpath.zig").PathRule;
pub const RingBuffer = @import("spsc_ringbuffer.zig").RingBuffer;

pub const WsServer = @import("ws/server.zig").WsServer;
pub const WsHandler = @import("ws/server.zig").WsHandler;
pub const Frame = @import("ws/types.zig").Frame;
pub const Opcode = @import("ws/types.zig").Opcode;

/// 用户自定义 io_uring 提交队列（Worker → IO 线程）
pub const SubmitQueue = @import("next/queue.zig").SubmitQueue;
pub const QueueItem = @import("next/queue.zig").Item;
pub const Next = @import("next/next.zig").Next;

/// 高级范式：用户自定义 I/O 请求，push 到 SubmitQueue，
/// IO 线程执行 execute，完成后调 on_complete。
/// 同一范式适用于 DB、Redis、NATS、HTTP Client。
pub const Fiber = @import("next/fiber.zig").Fiber;

/// IO 线程 TCP 出站客户端（io_uring 驱动），用于集成 NATS / Redis / HTTP client 等
pub const RingShared = @import("ring_shared.zig").RingShared;
pub const RingSharedClient = @import("next/client.zig").RingSharedClient;
/// RingSharedClient / FileRead 等 io_uring 句柄的统一注册表
pub const IORegistry = @import("io_registry.zig").IORegistry;
/// 将 RingSharedClient 推模型适配为读写拉模型（通过 fiber yield/resume），
/// 使同步风格的协议库（pgz/myqzl 等）可直接跑在 IO 线程
pub const Pipe = @import("next/pipe.zig").Pipe;

pub const DnsCache = @import("dns/cache.zig").DnsCache;
pub const DnsResolver = @import("dns/resolver.zig").DnsResolver;
pub const InvokeQueue = @import("io_invoke.zig").InvokeQueue;

/// 独立 HTTP 客户端 Ring (Ring B) + HttpClient + c-ares DNS
pub const HttpRing = @import("httpclient/ring.zig").HttpRing;
pub const HttpClient = @import("httpclient/client.zig").HttpClient;
pub const HttpCaresDns = @import("httpclient/dns.zig").CaresDns;
pub const DNS_FD_MAGIC = @import("httpclient/dns.zig").DNS_FD_MAGIC;

pub const CustomTemplate = struct {
    pub fn createAndRegister(server: *AsyncServer) !*SubmitQueue {
        const q = try server.allocator.create(SubmitQueue);
        q.* = SubmitQueue.init();
        try server.registerSubmitQueue(q);
        return q;
    }
};

/// 在链式异步 I/O 结束时向客户端发 HTTP 响应。
/// handler 设 ctx.deferred = true，链式调用末端调 resp.json/text 发回数据。
pub const DeferredResponse = struct {
    server: *AsyncServer,
    conn_id: u64,
    allocator: Allocator,

    pub fn json(self: *const DeferredResponse, status: u16, body: []const u8) void {
        const duped = self.allocator.dupe(u8, body) catch return;
        self.server.sendDeferredResponse(self.conn_id, status, .json, duped);
    }

    pub fn text(self: *const DeferredResponse, status: u16, body: []const u8) void {
        const duped = self.allocator.dupe(u8, body) catch return;
        self.server.sendDeferredResponse(self.conn_id, status, .plain, duped);
    }
};

/// 封装 ctx.deferred=true + DeferredResponse 创建 + push SubmitQueue。
/// handler 里一行搞定：
///   try deferToQueue(DbCtx, ctx, db_queue, .{ .sql = "..." }, execFn, doneFn);
pub fn deferToQueue(
    comptime T: type,
    ctx: *Context,
    queue: *SubmitQueue,
    userCtx: T,
    comptime execFn: fn (*T, *const fn (?*anyopaque, []const u8) void) void,
    comptime doneFn: fn (*T, *DeferredResponse, []const u8) void,
) !void {
    const s = ctx.server orelse return;
    const server: *AsyncServer = @ptrCast(@alignCast(s));

    const resp = try ctx.allocator.create(DeferredResponse);
    errdefer ctx.allocator.destroy(resp);
    resp.* = .{ .server = server, .conn_id = ctx.conn_id, .allocator = ctx.allocator };

    const user = try ctx.allocator.create(T);
    errdefer ctx.allocator.destroy(user);
    user.* = userCtx;

    const W = struct {
        allocator: Allocator,
        resp: *DeferredResponse,
        user: *T,
    };
    const w = try ctx.allocator.create(W);
    errdefer ctx.allocator.destroy(w);
    w.* = .{ .allocator = ctx.allocator, .resp = resp, .user = user };

    ctx.deferred = true;

    if (!queue.push(QueueItem{
        .ctx = w,
        .execute = struct {
            fn exec(c: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
                const ww: *W = @ptrCast(@alignCast(c));
                execFn(ww.user, complete);
            }
        }.exec,
        .on_complete = struct {
            fn done(c: ?*anyopaque, result: []const u8) void {
                const ww: *W = @ptrCast(@alignCast(c));
                defer ww.allocator.destroy(ww);
                defer ww.allocator.destroy(ww.user);
                defer ww.allocator.destroy(ww.resp);
                doneFn(ww.user, ww.resp, result);
            }
        }.done,
    })) {
        ctx.allocator.destroy(w);
        ctx.allocator.destroy(user);
        ctx.allocator.destroy(resp);
        return error.QueueFull;
    }
}
