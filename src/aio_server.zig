const std = @import("std");
const Allocator = std.mem.Allocator;

// ========== Re-exports ==========
pub const MAX_HEADER_BUFFER_SIZE = @import("constants.zig").MAX_HEADER_BUFFER_SIZE;
pub const MAX_RESPONSE_BUFFER_SIZE = @import("constants.zig").MAX_RESPONSE_BUFFER_SIZE;
pub const MAX_CQES_BATCH = @import("constants.zig").MAX_CQES_BATCH;
pub const RING_ENTRIES = @import("constants.zig").RING_ENTRIES;
pub const TASK_QUEUE_SIZE = @import("constants.zig").TASK_QUEUE_SIZE;
pub const RESPONSE_QUEUE_SIZE = @import("constants.zig").RESPONSE_QUEUE_SIZE;
pub const BUFFER_SIZE = @import("constants.zig").BUFFER_SIZE;
pub const BUFFER_POOL_SIZE = @import("constants.zig").BUFFER_POOL_SIZE;
pub const WRITE_BUF_COUNT = @import("constants.zig").WRITE_BUF_COUNT;
pub const READ_BUF_COUNT = @import("constants.zig").READ_BUF_COUNT;
pub const READ_BUF_GROUP_ID = @import("constants.zig").READ_BUF_GROUP_ID;
pub const ACCEPT_USER_DATA = @import("constants.zig").ACCEPT_USER_DATA;
pub const MAX_FIXED_FILES = @import("constants.zig").MAX_FIXED_FILES;
pub const MAX_PATH_LENGTH = @import("constants.zig").MAX_PATH_LENGTH;

pub const Connection = @import("http/connection.zig").Connection;
pub const Context = @import("http/context.zig").Context;
pub const Middleware = @import("http/types.zig").Middleware;
pub const Handler = @import("http/types.zig").Handler;
pub const AsyncServer = @import("http/async_server.zig").AsyncServer;

// ========== Example ==========
const Example = struct {
    fn jwtMiddleware(allocator: Allocator, ctx: *Context) anyerror!bool {
        _ = allocator;
        std.debug.print("[Middleware] Request: {s}\n", .{ctx.path});
        ctx.text(401, "Unauthorized") catch {};
        return true;
    }

    fn logMiddleware(allocator: Allocator, ctx: *Context) anyerror!bool {
        _ = allocator;
        if (std.mem.startsWith(u8, ctx.path, "/admin")) {
            var it = std.mem.splitSequence(u8, ctx.request_data, "\r\n");
            while (it.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "Authorization:")) {
                    return false;
                }
            }
            std.debug.print("Auth denied for path={s}\n", .{ctx.path});
            return true;
        }
        return false;
    }

    fn helloHandler(allocator: Allocator, ctx: *Context) anyerror!void {
        const body = try std.fmt.allocPrint(allocator, "{{\"message\":\"Hello from worker! path={s}\"}}", .{ctx.path});
        ctx.body = body;
        ctx.content_type = .json;
        ctx.status = 200;
    }

    pub fn main() !void {
        var gpa = std.heap.DebugAllocator(.{}).init;
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();

        var io_backend = std.Io.Threaded.init(alloc, .{});
        defer io_backend.deinit();
        const io = io_backend.io();

        var server = try AsyncServer.init(alloc, io, "0.0.0.0:9090", null);
        defer server.deinit();

        try server.useThenRespondImmediately("/antpath-verify", jwtMiddleware);
        try server.use("/admin", logMiddleware);
        try server.register("/hello", helloHandler);
        try server.register("/admin/dashboard", helloHandler);

        std.debug.print("Server listening on http://0.0.0.0:9090\n", .{});
        try server.run();
    }
};

pub fn main() !void {
    try Example.main();
}
