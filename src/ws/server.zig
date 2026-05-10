const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("types.zig").Frame;
const Opcode = @import("types.zig").Opcode;

/// WebSocket 消息处理函数，在 I/O 线程中被调用，必须非阻塞且快速返回。
/// conn_id: 连接唯一标识
/// frame:   收到的帧（由调用方管理生命周期，handler 内不应保存引用）
/// ctx:     用户上下文（由 WsServer 的 ctx 字段传入）
pub const WsHandler = *const fn (conn_id: u64, frame: *const Frame, ctx: *anyopaque) void;

/// 发送 WebSocket 帧的函数类型，由父服务器提供。
pub const SendFn = *const fn (ctx: *anyopaque, conn_id: u64, opcode: Opcode, payload: []const u8) anyerror!void;

pub const WsServer = struct {
    allocator: Allocator,
    handlers: std.StringHashMap(WsHandler),
    active: std.AutoHashMap(u64, WsHandler),
    send_fn: SendFn,
    ctx: *anyopaque,

    pub fn init(allocator: Allocator, send_fn: SendFn) WsServer {
        return WsServer{
            .allocator = allocator,
            .handlers = std.StringHashMap(WsHandler).init(allocator),
            .active = std.AutoHashMap(u64, WsHandler).init(allocator),
            .send_fn = send_fn,
            .ctx = undefined,
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.active.deinit();
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.handlers.deinit();
    }

    /// 关闭所有活跃连接（发送 Close 帧）。
    /// 调用者应在销毁 WsServer 前调用，并随后关闭底层 TCP 连接。
    pub fn closeAllActive(self: *WsServer) void {
        var it = self.active.iterator();
        while (it.next()) |entry| {
            self.send_fn(self.ctx, entry.key_ptr.*, .close, "") catch |err| {
                std.debug.print("ws closeAllActive: failed to send close to conn {}: {}\n", .{ entry.key_ptr.*, err });
            };
        }
    }

    pub fn register(self: *WsServer, path: []const u8, handler: WsHandler) !void {
        const key = try self.allocator.dupe(u8, path);
        // 修改原因：WebSocket 路由表必须拥有 path key；否则调用方传入临时 buffer 后会留下悬空 key。
        errdefer self.allocator.free(key);
        const gop = try self.handlers.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(key);
        }
        gop.value_ptr.* = handler;
    }

    pub fn hasHandlers(self: *const WsServer) bool {
        return self.handlers.count() > 0;
    }

    pub fn getHandler(self: *const WsServer, path: []const u8) ?WsHandler {
        return self.handlers.get(path);
    }

    pub fn addActive(self: *WsServer, conn_id: u64, handler: WsHandler) !void {
        try self.active.put(conn_id, handler);
    }

    pub fn removeActive(self: *WsServer, conn_id: u64) void {
        _ = self.active.remove(conn_id);
    }

    pub fn getActive(self: *const WsServer, conn_id: u64) ?WsHandler {
        return self.active.get(conn_id);
    }

    pub fn sendWsFrame(self: *WsServer, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
        try self.send_fn(self.ctx, conn_id, opcode, payload);
    }
};

/// 自动响应 WebSocket 控制帧。
/// 返回 true 表示应关闭连接（收到 Close 帧）。
pub fn handleControlFrame(server: *WsServer, conn_id: u64, opcode: Opcode, payload: []const u8) !bool {
    switch (opcode) {
        .ping => {
            try server.sendWsFrame(conn_id, .pong, payload);
            return false;
        },
        .pong => return false,
        .close => {
            try server.sendWsFrame(conn_id, .close, payload);
            return true;
        },
        else => return false,
    }
}

test "WsServer basic" {
    const allocator = std.testing.allocator;

    var last_sent: struct { conn_id: u64, opcode: Opcode } = undefined;
    _ = &last_sent;
    const send_fn = struct {
        fn send(ctx: *anyopaque, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
            _ = payload;
            const state = @as(*@TypeOf(last_sent), @ptrCast(@alignCast(ctx)));
            state.* = .{ .conn_id = conn_id, .opcode = opcode };
        }
    }.send;

    var state = last_sent;
    var server = WsServer.init(allocator, send_fn);
    server.ctx = &state;
    defer server.deinit();

    try server.register("/test", struct {
        fn h(_: u64, _: *const Frame, _: *anyopaque) void {}
    }.h);

    try std.testing.expect(server.getHandler("/test") != null);
    try std.testing.expect(server.getHandler("/notfound") == null);
    try std.testing.expect(server.hasHandlers());

    try server.addActive(42, server.getHandler("/test").?);
    try std.testing.expect(server.getActive(42) != null);
    server.removeActive(42);
    try std.testing.expect(server.getActive(42) == null);
}

test "WsServer register owns path keys" {
    const allocator = std.testing.allocator;

    const send_fn = struct {
        fn send(_: *anyopaque, _: u64, _: Opcode, _: []const u8) !void {}
    }.send;
    const handler = struct {
        fn h(_: u64, _: *const Frame, _: *anyopaque) void {}
    }.h;

    var server = WsServer.init(allocator, send_fn);
    server.ctx = undefined;
    defer server.deinit();

    const dynamic_path = try allocator.dupe(u8, "/dynamic");
    try server.register(dynamic_path, handler);
    allocator.free(dynamic_path);

    try std.testing.expect(server.getHandler("/dynamic") != null);
    try server.register("/dynamic", handler);
    try std.testing.expect(server.getHandler("/dynamic") != null);
}
