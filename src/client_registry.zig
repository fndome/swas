const std = @import("std");
const Allocator = std.mem.Allocator;
pub const CLIENT_USER_DATA_FLAG: u64 = 1 << 62;

pub const CqeDispatchFn = *const fn (*anyopaque, i32) void;

pub const ClientRegistry = struct {
    streams: std.AutoHashMap(u64, *anyopaque),
    next_ud: u64 = CLIENT_USER_DATA_FLAG,
    dispatch_fn: CqeDispatchFn = undefined,

    pub fn init(allocator: Allocator) ClientRegistry {
        return .{ .streams = std.AutoHashMap(u64, *anyopaque).init(allocator) };
    }

    pub fn deinit(self: *ClientRegistry) void {
        self.streams.deinit();
    }

    pub fn allocUserData(self: *ClientRegistry) u64 {
        const ud = self.next_ud;
        self.next_ud +%= 1;
        return ud;
    }

    pub fn register(self: *ClientRegistry, ud: u64, ptr: *anyopaque) !void {
        try self.streams.put(ud, ptr);
    }

    pub fn remove(self: *ClientRegistry, ud: u64) void {
        _ = self.streams.remove(ud);
    }

    pub fn dispatch(self: *ClientRegistry, ud: u64, res: i32) void {
        if (self.streams.getPtr(ud)) |pp| {
            self.dispatch_fn(pp.*, res);
        }
    }
};
