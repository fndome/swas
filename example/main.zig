const std = @import("std");

const sws = @import("sws");
const AsyncServer = sws.AsyncServer;

const query_go = @import("db_query_go.zig");
const llmr_submit = @import("cpu_llmr_submit.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var io_backend = std.Io.Threaded.init(alloc, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var server = try AsyncServer.init(alloc, io, "0.0.0.0:9090", null, 64);
    defer server.deinit();

    try server.initPool4NextSubmit(2);
    try server.GET("/users", query_go.findUsers);
    try server.POST("/infer", llmr_submit.inferHandler);

    server.installSigterm();

    std.debug.print("listening on :9090\n", .{});
    try server.run();
}
