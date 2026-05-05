const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const IORegistry = @import("../shared/io_registry.zig").IORegistry;
const RingShared = @import("../shared/ring_shared.zig").RingShared;
const InvokeQueue = @import("../shared/io_invoke.zig").InvokeQueue;
const DnsResolver = @import("../dns/resolver.zig").DnsResolver;
const CLIENT_USER_DATA_FLAG = @import("../shared/io_registry.zig").CLIENT_USER_DATA_FLAG;

/// 独立 HTTP 客户端 io_uring Ring (Ring B)。
///
/// 一根线程一个 Ring，所有外发 HTTP 请求共享同一个 Ring B。
/// 与 Server Ring (Ring A) 通过 ATTACH_WQ 共享内核 io-wq。
pub const HttpRing = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    registry: IORegistry,
    rs: RingShared,
    dns: DnsResolver,
    invoke: InvokeQueue,
    stop_flag: bool,

    pub fn init(allocator: Allocator, io: std.Io, entries: u16, attach_ring_fd: ?i32) !HttpRing {
        const ns_ip = readResolvConfNameserver() catch @as(u32, 0x08080808);

        var ring = if (attach_ring_fd) |fd| brk: {
            var params = std.mem.zeroes(linux.io_uring_params);
            params.flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_ATTACH_WQ;
            params.wq_fd = @intCast(fd);
            break :brk try linux.IoUring.init_params(entries, &params);
        } else try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();

        var registry = IORegistry.init(allocator);
        errdefer registry.deinit();

        const rs = RingShared.bind(&ring, &registry);

        const dns = try DnsResolver.init(allocator, &ring, &registry, io, ns_ip);
        errdefer dns.deinit();

        return HttpRing{
            .allocator = allocator,
            .ring = ring,
            .registry = registry,
            .rs = rs,
            .dns = dns,
            .invoke = .{},
            .stop_flag = false,
        };
    }

    pub fn deinit(self: *HttpRing) void {
        self.dns.deinit();
        self.registry.deinit();
        self.ring.deinit();
    }

    pub fn stop(self: *HttpRing) void {
        self.stop_flag = true;
    }

    /// 事件循环 — 驱动 Ring B 上所有 I/O（DNS + HTTP TCP 连接）。
    pub fn runLoop(self: *HttpRing) void {
        var cqes: [64]linux.io_uring_cqe = undefined;
        while (!self.stop_flag) {
            self.dns.tick();
            self.invoke.drain(self.allocator);
            _ = self.ring.submit() catch {};
            const n = self.ring.copy_cqes(&cqes, 0) catch continue;

            for (cqes[0..n]) |*cqe| {
                defer self.ring.cqe_seen(cqe);
                const ud = cqe.user_data;
                const res = cqe.res;
                if (ud & CLIENT_USER_DATA_FLAG != 0) {
                    self.registry.dispatch(ud, res);
                }
            }
        }
    }
};

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
