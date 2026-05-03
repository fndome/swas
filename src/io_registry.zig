const std = @import("std");
const Allocator = std.mem.Allocator;
pub const CLIENT_USER_DATA_FLAG: u64 = 1 << 62;

pub const CqeDispatchFn = *const fn (*anyopaque, i32) void;

const RegisteredEntry = struct {
    ptr: *anyopaque,
    dispatch: CqeDispatchFn,
};

pub const IORegistry = struct {
    streams: std.AutoHashMap(u64, RegisteredEntry),
    next_ud: u64 = CLIENT_USER_DATA_FLAG,

    pub fn init(allocator: Allocator) IORegistry {
        return .{ .streams = std.AutoHashMap(u64, RegisteredEntry).init(allocator) };
    }

    pub fn deinit(self: *IORegistry) void {
        self.streams.deinit();
    }

    pub fn allocUserData(self: *IORegistry) u64 {
        const ud = self.next_ud;
        self.next_ud +%= 1;
        return ud;
    }

    pub fn register(self: *IORegistry, ud: u64, ptr: *anyopaque, on_cqe: CqeDispatchFn) !void {
        try self.streams.put(ud, .{ .ptr = ptr, .dispatch = on_cqe });
    }

    pub fn remove(self: *IORegistry, ud: u64) void {
        _ = self.streams.remove(ud);
    }

    pub fn dispatch(self: *IORegistry, ud: u64, res: i32) void {
        if (self.streams.getPtr(ud)) |entry| {
            entry.dispatch(entry.ptr, res);
        }
    }
};
