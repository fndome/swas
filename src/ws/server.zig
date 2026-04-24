const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("types.zig").Frame;
const Opcode = @import("types.zig").Opcode;

pub const WsHandler = *const fn (conn_id: u64, frame: *const Frame, server: ?*anyopaque) void;

pub const WsHandlerEntry = struct {
    handler: WsHandler,
    user_data: ?*anyopaque,
};

pub const WsActiveConn = struct {
    handler: WsHandler,
    user_data: ?*anyopaque,
};

pub const WsServer = struct {
    allocator: Allocator,
    handlers: std.StringHashMap(WsHandlerEntry),
    active: std.AutoHashMap(u64, WsActiveConn),

    pub fn init(allocator: Allocator) WsServer {
        return WsServer{
            .allocator = allocator,
            .handlers = std.StringHashMap(WsHandlerEntry).init(allocator),
            .active = std.AutoHashMap(u64, WsActiveConn).init(allocator),
        };
    }

    pub fn deinit(self: *WsServer) void {
        var it = self.active.iterator();
        while (it.next()) |entry| {
            _ = entry.key_ptr;
        }
        self.active.deinit();
        self.handlers.deinit();
    }

    pub fn register(self: *WsServer, path: []const u8, handler: WsHandler, user_data: ?*anyopaque) !void {
        try self.handlers.put(path, .{ .handler = handler, .user_data = user_data });
    }

    pub fn hasHandlers(self: *const WsServer) bool {
        return self.handlers.count() > 0;
    }

    pub fn getHandler(self: *const WsServer, path: []const u8) ?WsHandlerEntry {
        const entry = self.handlers.get(path) orelse return null;
        return entry;
    }

    pub fn getActive(self: *const WsServer, conn_id: u64) ?WsActiveConn {
        return self.active.get(conn_id);
    }

    pub fn addActive(self: *WsServer, conn_id: u64, handler: WsHandler, user_data: ?*anyopaque) !void {
        try self.active.put(conn_id, .{ .handler = handler, .user_data = user_data });
    }

    pub fn removeActive(self: *WsServer, conn_id: u64) void {
        _ = self.active.remove(conn_id);
    }
};
