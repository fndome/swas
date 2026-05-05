const std = @import("std");
const Allocator = std.mem.Allocator;

const RingSharedClient = @import("../shared/tcp_stream.zig").RingSharedClient;
const Pipe = @import("../next/pipe.zig").Pipe;

/// ── 出站连接缓存基石 ────────────────────────────────────
///
/// 单条目 TTL 缓存。同 host:port 且未过期时复用 TCP 连接和 Pipe。
/// HTTP / NATS / MySQL 等协议 client 共用此基础件。
///
/// 设计原则（io_uring 微服务最佳实践）：
///   连接阶段允许重试——connect 失败不影响缓存，下次 getPipe 自动重建。
///   读写阶段禁止重试——write/read 失败立即 evict + 返回错误给调用方。
///   原因：io_uring SQE 级的 partial write 由内核 TCP 栈保证；应用层
///   重试 read/write 会造成协议帧边界错乱（HTTP 管线化、WS 帧、DB 协议包）。
///   调用方（handler fiber）如需重试，应重新发起完整请求，触发全新 connect。
///
/// 用法 (from main):
///   server.http_cache = TinyCache.init(alloc, 1000);  // 1s TTL
pub const TinyCache = struct {
    allocator: Allocator,
    ttl_ms: i64,
    stream: ?*RingSharedClient = null,
    pipe: ?Pipe = null,
    host: ?[]const u8 = null,
    port: u16 = 0,
    last_used_ms: i64 = 0,

    pub fn init(allocator: Allocator, ttl_ms: i64) TinyCache {
        return TinyCache{ .allocator = allocator, .ttl_ms = ttl_ms };
    }

    pub fn deinit(self: *TinyCache) void {
        self.evict();
    }

    /// 缓存命中时返回 pipe 指针，调用方通过 threadlocal 设置 active_pipe。
    /// 未命中时返回 null，调用方负责创建新连接后调用 store()。
    pub fn getPipe(self: *TinyCache, host: []const u8, port: u16, now_ms: i64) ?*Pipe {
        if (self.stream == null) return null;
        if (self.port != port) return null;
        if (self.host == null) return null;
        if (!std.mem.eql(u8, self.host.?, host)) return null;
        if (now_ms - self.last_used_ms >= self.ttl_ms) {
            self.evict();
            return null;
        }
        self.pipe.?.reset();
        self.last_used_ms = now_ms;
        return &self.pipe.?;
    }

    /// 淘汰当前缓存的连接。
    /// 安全：stream.deinit() 内 rs.remove(id) 注销 IORegistry 回调，
    /// 后续任何在途 CQE 到达时 dispatch 查 hashmap 无匹配，静默丢弃。
    /// 不会发生 use-after-free。
    pub fn evict(self: *TinyCache) void {
        if (self.stream) |s| {
            s.deinit();
            self.stream = null;
        }
        if (self.pipe) |*p| {
            p.deinit();
            self.pipe = null;
        }
        if (self.host) |h| {
            self.allocator.free(h);
            self.host = null;
        }
        self.port = 0;
    }

    /// 存储新连接到缓存
    pub fn store(self: *TinyCache, stream: *RingSharedClient, p: Pipe, host: []const u8, port: u16, now_ms: i64) !void {
        self.evict();
        const host_dup = try self.allocator.dupe(u8, host);
        self.stream = stream;
        self.pipe = p;
        self.host = host_dup;
        self.port = port;
        self.last_used_ms = now_ms;
    }

    /// 续期：标记缓存为刚使用
    pub fn touch(self: *TinyCache, now_ms: i64) void {
        self.last_used_ms = now_ms;
    }

    /// 周期调用（如 server.addHookTick），TTL 过期时主动淘汰空闲连接。
    /// 零成本：无缓存或未过期时仅一次时间戳比较。
    pub fn tick(self: *TinyCache, now_ms: i64) void {
        if (self.stream != null and now_ms - self.last_used_ms >= self.ttl_ms) {
            self.evict();
        }
    }
};
