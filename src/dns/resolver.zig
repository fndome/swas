const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const packet = @import("packet.zig");
const cache_mod = @import("cache.zig");
const DnsCache = cache_mod.DnsCache;
const Fiber = @import("../next/fiber.zig").Fiber;
const RingShared = @import("../ring_shared.zig").RingShared;

const DNS_TIMEOUT_MS: i64 = 2000;
const MAX_RETRIES: u8 = 2;

const PendingQuery = struct {
    txid: u16,
    hostname: []const u8,
    deadline_ms: i64,
    retries: u8,
    slot: Fiber.DnsYieldSlot,
};

const QueryResult = struct {
    addrs: [packet.AddrList.MAX_ADDRS]u32,
    len: u8,
    ttl: u32,
};

fn dnsDispatch(ptr: *anyopaque, res: i32) void {
    const self: *DnsResolver = @ptrCast(@alignCast(ptr));
    self.handleCqe(res);
}

pub const DnsResolver = struct {
    allocator: std.mem.Allocator,
    rs: RingShared,
    io: std.Io,
    udp_fd: i32,
    dns_ud: u64,
    nameserver_ip: u32,
    nameserver_port: u16,
    cache: DnsCache,
    pending: std.AutoHashMap(u16, PendingQuery),
    results: std.AutoHashMap(u16, QueryResult),
    next_txid: u16,
    recv_buf: [packet.MAX_PACKET_SIZE]u8,
    recv_outstanding: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        ring: *linux.IoUring,
        registry: *@import("../io_registry.zig").IORegistry,
        io: std.Io,
        nameserver_ip: u32,
    ) !DnsResolver {
        const raw_fd = linux.socket(
            linux.AF.INET,
            linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
        );
        const fd: i32 = @intCast(raw_fd);
        if (fd < 0) return error.UdpSocketFailed;

        var addr_any = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = 0,
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        if (linux.bind(fd, @ptrCast(&addr_any), @sizeOf(linux.sockaddr.in)) != 0) {
            _ = linux.close(fd);
            return error.BindFailed;
        }

        const rs = RingShared.bind(ring, registry);
        const dns_ud = try rs.alloc(@ptrCast(@constCast(&fd)), &dnsDispatch);

        return DnsResolver{
            .allocator = allocator,
            .rs = rs,
            .io = io,
            .udp_fd = fd,
            .dns_ud = dns_ud,
            .nameserver_ip = nameserver_ip,
            .nameserver_port = packet.DNS_PORT,
            .cache = DnsCache.init(allocator),
            .pending = std.AutoHashMap(u16, PendingQuery).init(allocator),
            .results = std.AutoHashMap(u16, QueryResult).init(allocator),
            .next_txid = 1,
            .recv_buf = [_]u8{0} ** packet.MAX_PACKET_SIZE,
            .recv_outstanding = false,
        };
    }

    pub fn deinit(self: *DnsResolver) void {
        self.cache.deinit();
        self.pending.deinit();
        self.results.deinit();
        self.rs.remove(self.dns_ud);
        if (self.udp_fd >= 0) {
            _ = linux.close(self.udp_fd);
            self.udp_fd = -1;
        }
    }

    fn nowMs(self: *DnsResolver) i64 {
        const ts = std.Io.Timestamp.now(self.io, .real);
        return @as(i64, @intCast(@divTrunc(ts.nanoseconds, @as(i96, std.time.ns_per_ms))));
    }

    fn nextTxid(self: *DnsResolver) u16 {
        const txid = self.next_txid;
        self.next_txid +%= 1;
        return txid;
    }

    pub fn resolve(self: *DnsResolver, hostname: []const u8) !u32 {
        const now = self.nowMs();

        if (self.cache.get(hostname, now)) |cached| {
            return cached.addrs[0];
        }

        const txid = self.nextTxid();

        try self.sendQuery(hostname, txid);

        const pq = PendingQuery{
            .txid = txid,
            .hostname = hostname,
            .deadline_ms = now + DNS_TIMEOUT_MS,
            .retries = 0,
            .slot = undefined,
        };
        try self.pending.put(txid, pq);

        Fiber.dnsYield(&self.pending.getPtr(txid).?.slot);

        const result = self.results.fetchRemove(txid) orelse return error.DnsTimeout;

        if (result.value.len > 0) {
            try self.cache.put(hostname, result.value.addrs[0..result.value.len], result.value.ttl, self.nowMs(), false);
            return result.value.addrs[0];
        }
        return error.DomainNotFound;
    }

    fn sendQuery(self: *DnsResolver, hostname: []const u8, txid: u16) !void {
        const query = try packet.buildQuery(hostname, txid);
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(self.nameserver_port),
            .addr = self.nameserver_ip,
            .zero = [_]u8{0} ** 8,
        };
        _ = linux.sendto(self.udp_fd, &query, query.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        self.submitRecv();
    }

    fn submitRecv(self: *DnsResolver) void {
        if (self.recv_outstanding) return;
        const sqe = self.rs.ring.nop(self.dns_ud) catch return;
        sqe.opcode = @enumFromInt(28); // IORING_OP_RECV
        sqe.fd = self.udp_fd;
        sqe.addr = @intFromPtr(&self.recv_buf);
        sqe.len = self.recv_buf.len;
        sqe.off = 0;
        self.recv_outstanding = true;
    }

    pub fn handleCqe(self: *DnsResolver, res: i32) void {
        self.recv_outstanding = false;
        if (res <= 0) return;

        const n: usize = @intCast(res);
        if (n < 12) return;

        const txid = packet.parseTxid(self.recv_buf[0..n]);
        const parsed = packet.parseResponse(self.recv_buf[0..n]);

        const pending = self.pending.fetchRemove(txid) orelse {
            if (self.pending.count() > 0) self.submitRecv();
            return;
        };

        var result = QueryResult{
            .addrs = [_]u32{0} ** packet.AddrList.MAX_ADDRS,
            .len = parsed.addrs.len,
            .ttl = parsed.ttl,
        };
        if (parsed.rcode == .NOERROR and parsed.addrs.len > 0) {
            @memcpy(result.addrs[0..parsed.addrs.len], parsed.addrs.addrs[0..parsed.addrs.len]);
        }
        self.results.put(txid, result) catch {};

        Fiber.dnsResume(&pending.value.slot);

        if (self.pending.count() > 0) self.submitRecv();
    }

    pub fn tick(self: *DnsResolver) void {
        const now = self.nowMs();
        self.cache.evictExpired(now);

        var timed_out = std.ArrayList(u16).empty;
        defer timed_out.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.deadline_ms) {
                timed_out.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (timed_out.items) |txid| {
            const pq = self.pending.getPtr(txid) orelse continue;
            if (pq.retries < MAX_RETRIES) {
                pq.retries += 1;
                pq.deadline_ms = now + DNS_TIMEOUT_MS;
                self.sendQuery(pq.hostname, pq.txid) catch {
                    const removed = self.pending.fetchRemove(txid) orelse continue;
                    Fiber.dnsResume(&removed.value.slot);
                };
            } else {
                const removed = self.pending.fetchRemove(txid) orelse continue;
                const empty_result = QueryResult{
                    .addrs = [_]u32{0} ** packet.AddrList.MAX_ADDRS,
                    .len = 0,
                    .ttl = 0,
                };
                self.results.put(txid, empty_result) catch {};
                Fiber.dnsResume(&removed.value.slot);
            }
        }
    }
};
