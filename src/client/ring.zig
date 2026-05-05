const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const IORegistry = @import("../shared/io_registry.zig").IORegistry;
const RingShared = @import("../shared/ring_shared.zig").RingShared;
const InvokeQueue = @import("../shared/io_invoke.zig").InvokeQueue;
const DnsResolver = @import("../dns/resolver.zig").DnsResolver;
const CLIENT_USER_DATA_FLAG = @import("../shared/io_registry.zig").CLIENT_USER_DATA_FLAG;
const FiberShared = @import("../shared/fiber_shared.zig").FiberShared;
const RingTrait = @import("../shared/fiber_shared.zig").RingTrait;

const MAX_CQES_TICK = 64;

/// ── Ring B ────────────────────────────────────────────────
///
/// 出站 HTTP 客户端 IO 归口。
/// 持有 ring + RingShared + IORegistry + DnsResolver + InvokeQueue。
/// 通过 registerWith() 注入 FiberShared 调度胶水，零额外线程。
///
/// 用法：
///   const ring_b = try RingB.init(alloc, io, server.ring.fd);
///   defer ring_b.deinit();
///   try ring_b.registerWith(&fiber_shared);
///   const client = try HttpClient.init(alloc, &ring_b, 1000);
pub const RingB = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    registry: IORegistry,
    rs: RingShared,
    dns: DnsResolver,
    invoke: InvokeQueue,

    pub fn init(allocator: Allocator, io: std.Io, attach_ring_fd: i32) !RingB {
        const ns_ip = readResolvConfNameserver() catch @as(u32, 0x08080808);

        var ring = brk: {
            var params = std.mem.zeroes(linux.io_uring_params);
            params.flags = linux.IORING_SETUP_SINGLE_ISSUER |
                linux.IORING_SETUP_DEFER_TASKRUN |
                linux.IORING_SETUP_ATTACH_WQ;
            params.wq_fd = @intCast(attach_ring_fd);
            break :brk try linux.IoUring.init_params(256, &params);
        };
        errdefer ring.deinit();

        var registry = IORegistry.init(allocator);
        errdefer registry.deinit();

        const rs = RingShared.bind(&ring, &registry);
        const dns = try DnsResolver.init(allocator, &ring, &registry, io, ns_ip);
        errdefer dns.deinit();

        return RingB{
            .allocator = allocator,
            .ring = ring,
            .registry = registry,
            .rs = rs,
            .dns = dns,
            .invoke = .{},
        };
    }

    pub fn deinit(self: *RingB) void {
        self.invoke.drain(self.allocator);
        self.dns.deinit();
        self.registry.deinit();
        self.ring.deinit();
    }

    /// 注入 FiberShared 调度胶水
    pub fn registerWith(self: *RingB, fs: *FiberShared) !void {
        try fs.register(RingTrait{
            .ptr = self,
            .tickFn = tickCb,
        });
    }

    fn tickCb(ptr: *anyopaque) void {
        const self: *RingB = @ptrCast(@alignCast(ptr));
        self.tick();
    }

    /// 非阻塞收割 Ring B 的 CQE 并分发
    pub fn tick(self: *RingB) void {
        self.dns.tick();
        self.invoke.drain(self.allocator);
        _ = self.ring.submit() catch {};

        var cqes: [MAX_CQES_TICK]linux.io_uring_cqe = undefined;
        const n = self.ring.copy_cqes(&cqes, 0) catch return;
        for (cqes[0..n]) |*cqe| {
            defer self.ring.cqe_seen(cqe);
            const ud = cqe.user_data;
            if (ud & CLIENT_USER_DATA_FLAG != 0) {
                self.registry.dispatch(ud, cqe.res);
            }
        }
    }
};

/// 保留向下兼容别名
pub const HttpRing = RingB;

fn readResolvConfNameserver() !u32 {
    const path = "/etc/resolv.conf\x00";
    const flags: linux.O = @bitCast(@as(u32, 0));
    const raw_fd = linux.open(@ptrCast(path), flags, 0);
    if (raw_fd < 0) return error.FileNotFound;
    const fd: i32 = @intCast(raw_fd);
    defer _ = linux.close(fd);

    var buf: [4096]u8 = undefined;
    const raw = linux.read(fd, &buf, buf.len);
    const n_signed: isize = @bitCast(raw);
    if (n_signed <= 0) return error.FileNotFound;
    const content = buf[0..@as(usize, @intCast(n_signed))];

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver ")) {
            const ip_str = std.mem.trim(u8, trimmed["nameserver ".len..], " \t\r");
            if (parseIpv4(ip_str)) |ip| return ip else |_| continue;
        }
    }
    return error.NoNameserverFound;
}

fn parseIpv4(ip_str: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, ip_str, '.');
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidIp;
    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        (@as(u32, octets[3]));
}
