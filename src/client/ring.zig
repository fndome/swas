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
const TinyCache = @import("tiny_cache.zig").TinyCache;
const helpers = @import("../http/http_helpers.zig");
// 修复：消除 readResolvConfNameserver/parseIpv4 与本文件 http_helpers.zig 的代码重复。

const MAX_CQES_TICK = 64;

/// ── Ring B ────────────────────────────────────────────────
///
/// 出站 HTTP 客户端 IO 归口。
/// 持有 ring + RingShared + IORegistry + DnsResolver + InvokeQueue + TinyCache。
/// 通过 registerWith() 注入 FiberShared 调度胶水，零额外线程。
///
/// TinyCache 内建在 RingB 中，由 RingB.tick() 每轮自动淘汰过期连接，
/// 用户无需手动管理缓存生命周期。
///
/// 用法：
///   const ring_b = try RingB.init(alloc, io, server.ring.fd, 1000);
///   defer ring_b.deinit();
///   try ring_b.registerWith(&fiber_shared);
///   const client = try HttpClient.init(alloc, &ring_b);
pub const RingB = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    registry: IORegistry,
    rs: RingShared,
    dns: DnsResolver,
    invoke: InvokeQueue,
    /// 内建出站连接缓存：同 host:port 在 TTL 内复用 TCP 连接。
    /// RingB.tick() 自动淘汰过期条目，用户无需干预。
    http_cache: TinyCache,

    pub fn init(allocator: Allocator, io: std.Io, attach_ring_fd: i32, cache_ttl_ms: i64) !RingB {
        const ns_ip = helpers.readResolvConfNameserver() catch @as(u32, 0x08080808);

        var ring = brk: {
            var params = std.mem.zeroes(linux.io_uring_params);
            // 修改原因：RingB 可能由主流程创建后交给 IO tick 驱动，SINGLE_ISSUER 会要求创建/提交同线程。
            params.flags = linux.IORING_SETUP_DEFER_TASKRUN |
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
            .http_cache = TinyCache.init(allocator, cache_ttl_ms),
        };
    }

    pub fn deinit(self: *RingB) void {
        self.http_cache.deinit();
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

    /// 非阻塞收割 Ring B 的 CQE + 淘汰过期缓存连接。
    pub fn tick(self: *RingB) void {
        if (self.http_cache.enabled()) {
            self.http_cache.tick(nowMs());
        }
        self.dns.tick();
        self.invoke.drain(self.allocator);
        _ = self.ring.submit() catch {};

        var cqes: [MAX_CQES_TICK]linux.io_uring_cqe = undefined;
        const n = self.ring.copy_cqes(&cqes, 0) catch return;
        // 修改原因：copy_cqes 会自动推进 CQ head，不能再对复制出来的 CQE 调 cqe_seen。
        for (cqes[0..n]) |*cqe| {
            const ud = cqe.user_data;
            if (ud & CLIENT_USER_DATA_FLAG != 0) {
                self.registry.dispatch(ud, cqe.res);
            }
        }
    }
};

/// 保留向下兼容别名
pub const HttpRing = RingB;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}
