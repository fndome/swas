const std = @import("std");
const linux = std.os.linux;
const IORegistry = @import("io_registry.zig").IORegistry;
const CqeDispatchFn = @import("io_registry.zig").CqeDispatchFn;

/// 单 ring 共享资源。注入到 server 和各 client，一切平等。
pub const RingShared = struct {
    ring: *linux.IoUring,
    registry: *IORegistry,

    pub fn init(ring: *linux.IoUring, registry: *IORegistry) RingShared {
        return .{ .ring = ring, .registry = registry };
    }

    pub fn allocUserData(self: *const RingShared) u64 {
        return self.registry.allocUserData();
    }

    pub fn register(self: *const RingShared, ud: u64, ptr: *anyopaque, cb: CqeDispatchFn) !void {
        try self.registry.register(ud, ptr, cb);
    }

    pub fn remove(self: *const RingShared, ud: u64) void {
        self.registry.remove(ud);
    }

    pub fn alloc(self: *const RingShared, ptr: *anyopaque, cb: CqeDispatchFn) !u64 {
        const ud = self.registry.allocUserData();
        try self.registry.register(ud, ptr, cb);
        return ud;
    }
};
