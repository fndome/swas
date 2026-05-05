const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const RingShared = @import("../shared/ring_shared.zig").RingShared;
const Fiber = @import("../next/fiber.zig").Fiber;

const c = @cImport({
    @cInclude("ares.h");
});

pub const DNS_FD_MAGIC: u64 = 0xCADE_0000_0000_0000;

pub const CaresDns = struct {
    allocator: Allocator,
    channel: c.ares_channel,
    rs: RingShared,
    result_ip: u32 = 0,
    result_ok: bool = false,
    slot: Fiber.DnsYieldSlot = undefined,
    registered_fds: [8]i32 = [_]i32{-1} ** 8,

    pub fn init(allocator: Allocator, rs: RingShared) !CaresDns {
        var channel: c.ares_channel = undefined;
        const status = c.ares_init(&channel);
        if (status != c.ARES_SUCCESS) {
            std.log.err("c-ares init failed: {s}", .{c.ares_strerror(status)});
            return error.DnsInitFailed;
        }
        return CaresDns{
            .allocator = allocator,
            .channel = channel,
            .rs = rs,
        };
    }

    pub fn deinit(self: *CaresDns) void {
        self.removeFds();
        c.ares_destroy(self.channel);
    }

    pub fn resolve(self: *CaresDns, hostname: []const u8) !u32 {
        const host_z = try self.allocator.alloc(u8, hostname.len + 1);
        defer self.allocator.free(host_z);
        @memcpy(host_z[0..hostname.len], hostname);
        host_z[hostname.len] = 0;

        self.result_ok = false;
        self.result_ip = 0;

        c.ares_gethostbyname(
            self.channel,
            @ptrCast(host_z.ptr),
            c.AF_INET,
            dnsCallback,
            self,
        );

        self.registerFds();

        Fiber.dnsYield(&self.slot);

        self.removeFds();

        if (!self.result_ok) return error.DomainNotFound;
        return self.result_ip;
    }

    pub fn tick(self: *CaresDns) void {
        c.ares_process_fd(self.channel, c.ARES_SOCKET_BAD, c.ARES_SOCKET_BAD);
    }

    pub fn handleCqe(self: *CaresDns, ud: u64, res: i32) void {
        _ = res;
        const fd: c_int = @intCast(ud - DNS_FD_MAGIC);
        c.ares_process_fd(self.channel, fd, c.ARES_SOCKET_BAD);
        self.registerFds();
    }

    fn registerFds(self: *CaresDns) void {
        self.removeFds();
        var fds: c.fd_set = undefined;
        var wfds: c.fd_set = undefined;
        _ = @memset(@as([*]u8, @ptrCast(&fds))[0..@sizeOf(c.fd_set)], 0);
        _ = @memset(@as([*]u8, @ptrCast(&wfds))[0..@sizeOf(c.fd_set)], 0);

        const nfds = c.ares_fds(self.channel, &fds, &wfds);
        var registered_count: usize = 0;
        var fd: c_int = 0;
        while (fd < nfds and registered_count < self.registered_fds.len) : (fd += 1) {
            const need_read = c.FD_ISSET(fd, &fds) != 0;
            const need_write = c.FD_ISSET(fd, &wfds) != 0;
            if (!need_read and !need_write) continue;

            const user_data = DNS_FD_MAGIC + @as(u64, @intCast(fd));
            const sqe = self.rs.ring.nop(user_data) catch continue;
            sqe.opcode = @enumFromInt(6); // IORING_OP_POLL_ADD
            sqe.fd = @intCast(fd);
            sqe.poll_events = if (need_write) @as(u32, 5) else @as(u32, 1);
            sqe.len = 1;

            self.registered_fds[registered_count] = @intCast(fd);
            registered_count += 1;
        }
    }

    fn removeFds(self: *CaresDns) void {
        for (&self.registered_fds) |*fd_ptr| {
            if (fd_ptr.* >= 0) {
                const fd = fd_ptr.*;
                const user_data = DNS_FD_MAGIC + @as(u64, @intCast(fd));
                const sqe = self.rs.ring.nop(user_data) catch continue;
                sqe.opcode = @enumFromInt(7); // IORING_OP_POLL_REMOVE
                sqe.fd = @intCast(fd);
                fd_ptr.* = -1;
            }
        }
    }

    fn dnsCallback(
        arg: ?*anyopaque,
        status: c_int,
        timeouts: c_int,
        hostent: ?*c.struct_hostent,
    ) callconv(.c) void {
        _ = timeouts;
        const self: *CaresDns = @ptrCast(@alignCast(arg));
        if (status != c.ARES_SUCCESS or hostent == null) {
            self.result_ok = false;
            return;
        }
        const h = hostent.?;
        if (h.h_addr_list == null or h.h_addr_list.?[0] == null) {
            self.result_ok = false;
            return;
        }
        const addr: *align(1) const u32 = @ptrCast(h.h_addr_list.?[0]);
        self.result_ip = addr.*;
        self.result_ok = true;
    }
};
