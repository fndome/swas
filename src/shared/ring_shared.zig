const std = @import("std");
const linux = std.os.linux;
const IORegistry = @import("io_registry.zig").IORegistry;
const CqeDispatchFn = @import("io_registry.zig").CqeDispatchFn;
const InvokeQueue = @import("io_invoke.zig").InvokeQueue;

/// 单 ring 共享资源。注入到 server 和各 client，一切平等。
pub const RingShared = struct {
    ring: *linux.IoUring,
    registry: *IORegistry,
    invoke: InvokeQueue,
    io_tid: std.Thread.Id,

    pub fn bind(ring: *linux.IoUring, registry: *IORegistry) RingShared {
        return .{
            .ring = ring,
            .registry = registry,
            .invoke = .{},
            .io_tid = std.Thread.getCurrentId(),
        };
    }

    /// 获取 ring（仅在 IO 线程合法）。Debug 下 worker 线程调用直接 panic。
    pub fn ringPtr(self: *const RingShared) *linux.IoUring {
        self.assertIoThread();
        return self.ring;
    }

    /// 获取 registry（仅在 IO 线程合法）。
    pub fn registryPtr(self: *const RingShared) *IORegistry {
        self.assertIoThread();
        return self.registry;
    }

    pub fn assertIoThread(self: *const RingShared) void {
        if (std.Thread.getCurrentId() != self.io_tid) {
            @panic("RingShared accessed from non-IO thread");
        }
    }

    pub fn allocUserData(self: *const RingShared) u64 {
        return self.registryPtr().allocUserData();
    }

    pub fn register(self: *const RingShared, ud: u64, ptr: *anyopaque, cb: CqeDispatchFn) !void {
        try self.registryPtr().register(ud, ptr, cb);
    }

    pub fn remove(self: *const RingShared, ud: u64) void {
        self.registryPtr().remove(ud);
    }

    pub fn alloc(self: *const RingShared, ptr: *anyopaque, cb: CqeDispatchFn) !u64 {
        const ud = self.registryPtr().allocUserData();
        try self.registryPtr().register(ud, ptr, cb);
        return ud;
    }
};
