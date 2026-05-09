const std = @import("std");
const Allocator = std.mem.Allocator;

const RingSharedClient = @import("../shared/tcp_stream.zig").RingSharedClient;
const Pipe = @import("../next/pipe.zig").Pipe;

/// ── 出站连接池 ──────────────────────────────────────────
///
/// 同 host:port 允许多条并发连接 (K8s pod 间通信需要)。
/// getPipe() 优先借出空闲连接，全部借出时返回 null 让调用方新建。
/// releasePipe() 归还到池。TTL 过期自动淘汰空闲连接。
///
/// 上限: MAX_CONNS_PER_HOST = 8
const MAX_CONNS_PER_HOST: usize = 12;

const PoolEntry = struct {
    host: []u8,
    port: u16,
    stream: *RingSharedClient,
    pipe: Pipe,
    last_used_ms: i64,
    borrowed: bool,
};

pub const TinyCache = struct {
    allocator: Allocator,
    ttl_ms: i64,
    entries: std.ArrayList(PoolEntry),

    pub fn init(allocator: Allocator, ttl_ms: i64) TinyCache {
        return TinyCache{
            .allocator = allocator,
            .ttl_ms = ttl_ms,
            .entries = std.ArrayList(PoolEntry).initCapacity(allocator, MAX_CONNS_PER_HOST) catch @panic("OOM"),
        };
    }

    pub fn enabled(self: *const TinyCache) bool {
        return self.ttl_ms > 0;
    }

    pub fn deinit(self: *TinyCache) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.host);
            e.stream.deinit();
            e.pipe.deinit();
        }
        self.entries.deinit(self.allocator);
    }

    /// 借出一条空闲连接到 host:port。返回 (stream, pipe) 或 null。
    pub fn acquire(self: *TinyCache, host: []const u8, port: u16, now_ms: i64) ?struct { stream: *RingSharedClient, pipe: *Pipe } {
        if (!self.enabled()) return null;
        for (self.entries.items) |*e| {
            if (e.borrowed) continue;
            if (e.port != port) continue;
            if (!std.mem.eql(u8, e.host, host)) continue;
            if (now_ms - e.last_used_ms >= self.ttl_ms) continue;
            e.pipe.reset();
            e.last_used_ms = now_ms;
            e.borrowed = true;
            return .{ .stream = e.stream, .pipe = &e.pipe };
        }
        return null;
    }

    /// 归还借出的连接。
    pub fn release(self: *TinyCache, p: *const Pipe, now_ms: i64) void {
        for (self.entries.items) |*e| {
            if (&e.pipe == p) {
                e.borrowed = false;
                e.last_used_ms = now_ms;
                return;
            }
        }
    }

    /// 存入新连接到池。池满时返回 error.PoolFull。
    pub fn store(self: *TinyCache, stream: *RingSharedClient, p: Pipe, host: []const u8, port: u16, now_ms: i64) !void {
        if (!self.enabled()) {
            stream.deinit();
            return;
        }
        self.evictExpired(now_ms);
        if (self.entries.items.len >= MAX_CONNS_PER_HOST) {
            stream.deinit();
            return error.PoolFull;
        }
        const host_dup = self.allocator.dupe(u8, host) catch {
            stream.deinit();
            return error.OutOfMemory;
        };
        try self.entries.append(.{
            .host = host_dup,
            .port = port,
            .stream = stream,
            .pipe = p,
            .last_used_ms = now_ms,
            .borrowed = false,
        });
    }

    /// 淘汰单条连接 (write/read 失败时用)
    pub fn evictPipe(self: *TinyCache, p: *const Pipe) void {
        for (self.entries.items, 0..) |*e, i| {
            if (&e.pipe == p) {
                self.allocator.free(e.host);
                e.stream.deinit();
                e.pipe.deinit();
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    pub fn pipeForStream(self: *TinyCache, stream: *RingSharedClient) ?*Pipe {
        // 修改原因：HTTP client 的回包必须按连接查找 Pipe，不能依赖 threadlocal active_pipe。
        for (self.entries.items) |*e| {
            if (e.stream == stream) return &e.pipe;
        }
        return null;
    }

    pub fn evictStream(self: *TinyCache, stream: *RingSharedClient) void {
        // 修改原因：连接关闭回调只知道 stream，需能稳定淘汰对应缓存项并释放 Pipe。
        for (self.entries.items, 0..) |*e, i| {
            if (e.stream == stream) {
                self.allocator.free(e.host);
                e.stream.deinit();
                e.pipe.deinit();
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// tick() 周期调用：淘汰过期且未借出的连接
    pub fn tick(self: *TinyCache, now_ms: i64) void {
        if (!self.enabled()) return;
        self.evictExpired(now_ms);
    }

    fn evictExpired(self: *TinyCache, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = &self.entries.items[i];
            if (!e.borrowed and now_ms - e.last_used_ms >= self.ttl_ms) {
                self.allocator.free(e.host);
                e.stream.deinit();
                e.pipe.deinit();
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn count(self: *const TinyCache) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.borrowed) n += 1;
        }
        return n;
    }
};
