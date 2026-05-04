const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const BufferPool = @import("../buffer_pool.zig").BufferPool;

const constants = @import("../constants.zig");
const RING_ENTRIES = constants.RING_ENTRIES;
const TASK_QUEUE_SIZE = constants.TASK_QUEUE_SIZE;
const BUFFER_POOL_SIZE = constants.BUFFER_POOL_SIZE;
const MAX_CQES_BATCH = constants.MAX_CQES_BATCH;
const ACCEPT_USER_DATA = constants.ACCEPT_USER_DATA;
const CLIENT_USER_DATA_FLAG = @import("../io_registry.zig").CLIENT_USER_DATA_FLAG;
const IORegistry = @import("../io_registry.zig").IORegistry;

const USER_TASK_BATCH = constants.USER_TASK_BATCH;
const MAX_FIXED_FILES = constants.MAX_FIXED_FILES;
const BUFFER_SIZE = constants.BUFFER_SIZE;
const READ_BUF_GROUP_ID = constants.READ_BUF_GROUP_ID;

const PathRule = @import("../antpath.zig").PathRule;
const uring_submit = @import("../next/queue.zig");
const SubmitQueueRegistry = uring_submit.SubmitQueueRegistry;
const Item = uring_submit.Item;
const Next = @import("../next/next.zig").Next;
const Fiber = @import("../next/fiber.zig").Fiber;

const Connection = @import("connection.zig").Connection;
const Context = @import("context.zig").Context;
const Middleware = @import("types.zig").Middleware;
const Handler = @import("types.zig").Handler;
const MiddlewareStore = @import("middleware_store.zig").MiddlewareStore;
const WildcardEntry = @import("middleware_store.zig").WildcardEntry;

const helpers = @import("http_helpers.zig");
const getMethodFromNextuest = helpers.getMethodFromRequest;
const getPathFromNextuest = helpers.getPathFromRequest;
const isKeepAliveConnection = helpers.isKeepAliveConnection;
const parseIpv4 = helpers.parseIpv4;
const logErr = helpers.logErr;

const WsServer = @import("../ws/server.zig").WsServer;
const WsHandler = @import("../ws/server.zig").WsHandler;
const Frame = @import("../ws/types.zig").Frame;
const Opcode = @import("../ws/types.zig").Opcode;
const ws_frame = @import("../ws/frame.zig");
const ws_upgrade = @import("../ws/upgrade.zig");

const DnsResolver = @import("../dns/resolver.zig").DnsResolver;
const DNS_USER_DATA_FLAG = @import("../dns/resolver.zig").DNS_USER_DATA_FLAG;
const InvokeQueue = @import("../io_invoke.zig").InvokeQueue;

fn milliTimestamp(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @as(i64, @intCast(@divTrunc(ts.nanoseconds, @as(i96, std.time.ns_per_ms))));
}

fn readResolvConfNameserver() !u32 {
    const path = "/etc/resolv.conf\x00";
    const flags: linux.O = @bitCast(@as(u32, 0));
    const raw_fd = linux.open(@ptrCast(path), flags, 0);
    if (raw_fd < 0) return error.FileNotFound;
    const fd: i32 = @intCast(raw_fd);
    defer _ = linux.close(fd);

    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (n == 0) return error.FileNotFound;
    const content = buf[0..n];

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver ")) {
            const ip_str = std.mem.trim(u8, trimmed["nameserver ".len..], " \t\r");
            if (helpers.parseIpv4(ip_str)) |ip| return ip else |_| continue;
        }
    }
    return error.NoNameserverFound;
}

threadlocal var pending_user_item: ?*const Item = null;

fn executeUserComplete(caller_ctx: ?*anyopaque, data: []const u8) void {
    const item = pending_user_item.?;
    item.on_complete(caller_ctx, data);
}

const DeferredNode = struct {
    next: ?*DeferredNode,
    conn_id: u64,
    status: u16,
    ct: Context.ContentType,
    body: []u8,
};

pub const AsyncServer = struct {
    allocator: Allocator,
    io: std.Io,
    ring: linux.IoUring,
    listen_fd: i32,
    next_conn_id: u64,
    connections: std.AutoHashMap(u64, Connection),
    next_user_data: u64,
    app_ctx: ?*anyopaque,

    should_stop: bool = false,
    buffer_pool: BufferPool,

    use_fixed_files: bool = false,
    fixed_file_freelist: std.ArrayList(u16),
    fixed_file_next: u16,

    ws_server: WsServer,
    middlewares: MiddlewareStore,
    respond_middlewares: MiddlewareStore,
    handlers: std.StringHashMap(Handler),

    timeout_user_data: u64 = 0,
    timeout_ts: linux.kernel_timespec = .{ .sec = 1, .nsec = 0 },

    cfg: Config,

    /// 线程安全：worker 线程通过 CAS push，IO 线程 swap 清空
    deferred_head: ?*DeferredNode align(@alignOf(usize)) = null,
    /// 通用跨线程 IO 回调队列
    invoke_queue: InvokeQueue,
    /// 钩子列表：在 drainDeferred 发送响应前依次调用（IO 线程内执行）
    deferred_hooks: std.ArrayList(*const fn (self: *Self, node: *DeferredNode) void),
    /// tick 钩子列表：每轮 IO 循环必触发（有/无 deferred 节点都跑）
    tick_hooks: std.ArrayList(*const fn (self: *Self) void),

    /// 客户端出站连接注册表（io_uring TCP client）
    io_registry: IORegistry,

    /// IO 线程已绑核标记
    io_pinned: bool = false,

    /// DNS 解析器 (io_uring 异步 UDP DNS)
    dns_resolver: DnsResolver,

    /// HTTP 请求 fiber 执行器
    next: ?Next = null,
    /// 用户自定义队列注册表
    submit_registry: SubmitQueueRegistry,

    /// 高频对象内存池，消除 per-request alloc
    http_ctx_pool: std.heap.MemoryPool(HttpTaskCtx),
    ws_ctx_pool: std.heap.MemoryPool(WsTaskCtx),
    /// 预分配的 fiber 共享栈（单 IO 线程串行复用）
    shared_fiber_stack: []u8,

    worker_orig_cpu_mask: usize = 0,

    const Self = @This();

    pub const Config = struct {
        max_header_buffer_size: u32 = constants.MAX_HEADER_BUFFER_SIZE,
        max_response_buffer_size: u32 = constants.MAX_RESPONSE_BUFFER_SIZE,
        max_cqes_batch: u32 = constants.MAX_CQES_BATCH,
        ring_entries: u32 = constants.RING_ENTRIES,
        task_queue_size: u32 = constants.TASK_QUEUE_SIZE,
        response_queue_size: u32 = constants.RESPONSE_QUEUE_SIZE,
        buffer_size: u32 = constants.BUFFER_SIZE,
        buffer_pool_size: u32 = constants.BUFFER_POOL_SIZE,
        max_fixed_files: u32 = constants.MAX_FIXED_FILES,
        max_path_length: u32 = constants.MAX_PATH_LENGTH,
        idle_timeout_ms: u64 = constants.IDLE_TIMEOUT_MS,
        write_timeout_ms: u64 = constants.WRITE_TIMEOUT_MS,
        fiber_stack_size_kb: u16 = 64,
        io_cpu: ?u6 = null,
    };

    pub const ConfigKey = enum {
        max_header_buffer_size,
        max_response_buffer_size,
        max_cqes_batch,
        ring_entries,
        task_queue_size,
        response_queue_size,
        buffer_size,
        buffer_pool_size,
        max_fixed_files,
        max_path_length,
        idle_timeout_ms,
        write_timeout_ms,
        io_cpu,
    };

    pub fn config(self: *Self, key: ConfigKey, value: i32) void {
        switch (key) {
            .max_header_buffer_size => self.cfg.max_header_buffer_size = @intCast(value),
            .max_response_buffer_size => self.cfg.max_response_buffer_size = @intCast(value),
            .max_cqes_batch => self.cfg.max_cqes_batch = @intCast(value),
            .ring_entries => self.cfg.ring_entries = @intCast(value),
            .task_queue_size => self.cfg.task_queue_size = @intCast(value),
            .response_queue_size => self.cfg.response_queue_size = @intCast(value),
            .buffer_size => self.cfg.buffer_size = @intCast(value),
            .buffer_pool_size => self.cfg.buffer_pool_size = @intCast(value),
            .max_fixed_files => self.cfg.max_fixed_files = @intCast(value),
            .max_path_length => self.cfg.max_path_length = @intCast(value),
            .idle_timeout_ms => self.cfg.idle_timeout_ms = @intCast(value),
            .write_timeout_ms => self.cfg.write_timeout_ms = @intCast(value),
            .io_cpu => self.cfg.io_cpu = if (value < 0) null else @intCast(value),
        }
    }

    pub fn init(allocator: Allocator, io: std.Io, listen_addr: []const u8, app_ctx: ?*anyopaque, fiber_stack_size_kb: u16) !Self {
        const colon = std.mem.indexOfScalar(u8, listen_addr, ':') orelse return error.InvalidListenAddress;
        const ip_str = listen_addr[0..colon];
        const port_str = listen_addr[colon + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const ip_addr = try parseIpv4(ip_str);

        const raw_fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        const fd = @as(i32, @intCast(raw_fd));
        if (fd < 0) return error.SocketCreationFailed;
        errdefer _ = linux.close(fd);

        var reuse: i32 = 1;
        const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @as([*]const u8, @ptrCast(&reuse)), @sizeOf(i32));
        if (rc != 0) return error.SetSockOptFailed;

        var addr_in = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(port),
            .addr = ip_addr,
            .zero = [_]u8{0} ** 8,
        };
        const len: u32 = @intCast(@sizeOf(linux.sockaddr.in));
        const rc_bind = linux.bind(fd, @ptrCast(&addr_in), len);
        if (rc_bind != 0) return error.BindFailed;
        const rc_listen = linux.listen(fd, 1024);
        if (rc_listen != 0) return error.ListenFailed;

        var params = std.mem.zeroes(linux.io_uring_params);
        params.flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
        params.sq_entries = 256;
        params.cq_entries = 256;
        var ring = linux.IoUring.init_params(RING_ENTRIES, &params) catch blk: {
            break :blk try linux.IoUring.init(RING_ENTRIES, 0);
        };
        errdefer ring.deinit();

        const mw_store = MiddlewareStore{
            .global = std.ArrayList(Middleware).empty,
            .precise = std.StringHashMap(std.ArrayList(Middleware)).init(allocator),
            .wildcard = std.ArrayList(WildcardEntry).empty,
            .has_global = false,
        };
        const respond_mw_store = MiddlewareStore{
            .global = std.ArrayList(Middleware).empty,
            .precise = std.StringHashMap(std.ArrayList(Middleware)).init(allocator),
            .wildcard = std.ArrayList(WildcardEntry).empty,
            .has_global = false,
        };

        var use_ff = false;
        const ff_freelist = std.ArrayList(u16).empty;
        if (ring.register_files_sparse(MAX_FIXED_FILES)) {
            use_ff = true;
        } else |_| {}

        var bp = try BufferPool.init(allocator, BUFFER_POOL_SIZE);
        errdefer bp.deinit();

        const kb = if (fiber_stack_size_kb == 0) @as(u16, 64) else fiber_stack_size_kb;
        const stack_size = @as(u32, @intCast(kb)) * 1024;
        const shared_stack = try allocator.alloc(u8, stack_size);
        errdefer allocator.free(shared_stack);

        const ns_ip = readResolvConfNameserver() catch @as(u32, 0x0a60000a);
        var dns_resolver = try DnsResolver.init(allocator, &ring, io, ns_ip);
        errdefer dns_resolver.deinit();

        var server = Self{
            .allocator = allocator,
            .io = io,
            .ring = ring,
            .listen_fd = fd,
            .next_conn_id = 1,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .deferred_hooks = std.ArrayList(*const fn (self: *Self, node: *DeferredNode) void).empty,
            .tick_hooks = std.ArrayList(*const fn (self: *Self) void).empty,
            .io_registry = IORegistry.init(allocator),
            .next_user_data = 1,
            .app_ctx = app_ctx,
            .buffer_pool = bp,
            .use_fixed_files = use_ff,
            .fixed_file_freelist = ff_freelist,
            .fixed_file_next = 0,
            .ws_server = WsServer.init(allocator, wsSendFn),
            .middlewares = mw_store,
            .respond_middlewares = respond_mw_store,
            .handlers = std.StringHashMap(Handler).init(allocator),
            .cfg = Config{ .fiber_stack_size_kb = kb },
            .io_pinned = false,
            .next = null,
            .submit_registry = SubmitQueueRegistry.init(allocator),
            .http_ctx_pool = std.heap.MemoryPool(HttpTaskCtx).empty,
            .ws_ctx_pool = std.heap.MemoryPool(WsTaskCtx).empty,
            .shared_fiber_stack = shared_stack,
            .dns_resolver = dns_resolver,
            .invoke_queue = .{},
        };

        server.ws_server.ctx = &server;
        try server.buffer_pool.provideAllReads(&server.ring);

        // 预分配内存池，消除冷启动时的动态分配
        try server.http_ctx_pool.addCapacity(allocator, 64);
        try server.ws_ctx_pool.addCapacity(allocator, 64);

        return server;
    }

    pub fn deinit(self: *Self) void {
        if (self.next) |*n| n.deinit();

        self.invoke_queue.drain(self.allocator);

        // Drain any pending deferred responses (worker threads already joined)
        var node = @atomicRmw(?*DeferredNode, &self.deferred_head, .Xchg, null, .acquire);
        while (node) |n| {
            self.allocator.free(n.body);
            const next = n.next;
            self.allocator.destroy(n);
            node = next;
        }

        var it = self.connections.iterator();

        while (it.next()) |entry| {
            if (entry.value_ptr.write_body) |b| self.allocator.free(b);
            if (entry.value_ptr.ws_token) |t| self.allocator.free(t);
            if (entry.value_ptr.response_buf) |buf| self.buffer_pool.freeTieredWriteBuf(buf, entry.value_ptr.response_buf_tier);
            const rc = linux.close(entry.value_ptr.fd);
            if (rc != 0) logErr("close fd={d} failed: {d}", .{ entry.value_ptr.fd, rc });
        }
        const lrc = linux.close(self.listen_fd);
        if (lrc != 0) logErr("close listen_fd={d} failed: {d}", .{ self.listen_fd, lrc });

        self.connections.deinit();
        self.deferred_hooks.deinit(self.allocator);
        self.tick_hooks.deinit(self.allocator);
        self.io_registry.deinit();
        self.submit_registry.deinit();
        self.ring.deinit();
        self.buffer_pool.deinit();
        self.fixed_file_freelist.deinit(self.allocator);
        self.ws_server.closeAllActive();
        self.ws_server.deinit();
        self.middlewares.deinit(self.allocator);
        self.respond_middlewares.deinit(self.allocator);
        {
            var handler_it = self.handlers.iterator();
            while (handler_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
        }
        self.handlers.deinit();
        self.http_ctx_pool.deinit(self.allocator);
        self.ws_ctx_pool.deinit(self.allocator);
        self.allocator.free(self.shared_fiber_stack);
        self.dns_resolver.deinit();
        self.cfg = undefined;
    }

    /// 注册中间件，在 fiber 中执行。可用 Next.submit() 卸 CPU 重活。
    pub fn use(self: *Self, pattern: []const u8, middleware: Middleware) !void {
        self.ensureNext();

        if (pattern.len == 0 or (pattern.len == 1 and pattern[0] == '/')) {
            return error.InvalidPattern;
        }
        if ((pattern.len == 3 and pattern[0] == '/' and pattern[1] == '*' and pattern[2] == '*') or
            (pattern.len == 2 and pattern[0] == '*' and pattern[1] == '*'))
        {
            try self.middlewares.global.append(self.allocator, middleware);
            self.middlewares.has_global = true;

            return;
        }
        if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
            const key = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(key);
            const gop = try self.middlewares.precise.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Middleware).empty;
            } else {
                self.allocator.free(key);
            }
            try gop.value_ptr.append(self.allocator, middleware);

            return;
        }
        for (self.middlewares.wildcard.items) |*entry| {
            if (std.mem.eql(u8, entry.rule.pattern, pattern)) {
                try entry.list.append(self.allocator, middleware);

                return;
            }
        }
        var new_list = std.ArrayList(Middleware).empty;
        try new_list.append(self.allocator, middleware);
        var rule = try PathRule.init(self.allocator, pattern);
        errdefer {
            new_list.deinit(self.allocator);
            rule.deinit();
        }
        try self.middlewares.wildcard.append(self.allocator, .{
            .rule = rule,
            .list = new_list,
        });
    }

    /// 注册快速中间件，在 IO 线程内联执行。⚠️ 不可阻塞。
    pub fn useThenRespondImmediately(self: *Self, pattern: []const u8, middleware: Middleware) !void {
        if (pattern.len == 0 or (pattern.len == 1 and pattern[0] == '/')) {
            return error.InvalidPattern;
        }
        if (pattern.len == 3 and pattern[0] == '/' and pattern[1] == '*' and pattern[2] == '*') {
            try self.respond_middlewares.global.append(self.allocator, middleware);
            self.respond_middlewares.has_global = true;
            return;
        }
        if (pattern.len == 2 and pattern[0] == '*' and pattern[1] == '*') {
            try self.respond_middlewares.global.append(self.allocator, middleware);
            self.respond_middlewares.has_global = true;
            return;
        }
        if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
            const key = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(key);
            const gop = try self.respond_middlewares.precise.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Middleware).empty;
            } else {
                self.allocator.free(key);
            }
            try gop.value_ptr.append(self.allocator, middleware);
            return;
        }
        for (self.respond_middlewares.wildcard.items) |*entry| {
            if (std.mem.eql(u8, entry.rule.pattern, pattern)) {
                try entry.list.append(self.allocator, middleware);
                return;
            }
        }
        var new_list = std.ArrayList(Middleware).empty;
        try new_list.append(self.allocator, middleware);
        var rule = try PathRule.init(self.allocator, pattern);
        errdefer {
            new_list.deinit(self.allocator);
            rule.deinit();
        }
        try self.respond_middlewares.wildcard.append(self.allocator, .{
            .rule = rule,
            .list = new_list,
        });
    }

    fn ensureNext(self: *Self) void {
        if (self.next != null) return;
        const kb = if (self.cfg.fiber_stack_size_kb == 0) @as(u16, 64) else self.cfg.fiber_stack_size_kb;
        self.next = Next.init(self.allocator, @as(u32, @intCast(kb)) * 1024);
        self.next.?.setDefault();
    }

    fn register(self: *Self, method: []const u8, path: []const u8, handler: Handler) !void {
        self.ensureNext();
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ method, path });
        const old = try self.handlers.fetchPut(key, handler);
        if (old) |kv| {
            self.allocator.free(kv.key);
        }
    }

    pub fn GET(self: *Self, path: []const u8, handler: Handler) !void {
        try self.register("GET", path, handler);
    }

    pub fn POST(self: *Self, path: []const u8, handler: Handler) !void {
        try self.register("POST", path, handler);
    }

    pub fn PUT(self: *Self, path: []const u8, handler: Handler) !void {
        try self.register("PUT", path, handler);
    }

    pub fn PATCH(self: *Self, path: []const u8, handler: Handler) !void {
        try self.register("PATCH", path, handler);
    }

    pub fn DELETE(self: *Self, path: []const u8, handler: Handler) !void {
        try self.register("DELETE", path, handler);
    }

    pub fn ws(self: *Self, path: []const u8, handler: WsHandler) !void {
        try self.ws_server.register(path, handler);
    }

    /// 跨线程安全投递回调到 IO 线程执行。execFn 负责释放 ctx 内部资源。
    pub fn invokeOnIoThread(
        self: *Self,
        comptime T: type,
        ctx: T,
        comptime execFn: fn (allocator: Allocator, ctx_ptr: *T) void,
    ) !void {
        try self.invoke_queue.push(self.allocator, T, ctx, execFn);
    }

    pub fn createClientStream(
        self: *Self,
        on_data: *const fn (ctx: ?*anyopaque, data: []u8) void,
        on_close: *const fn (ctx: ?*anyopaque) void,
        callback_ctx: ?*anyopaque,
    ) !*@import("../next/client.zig").ClientStream {
        return @import("../next/client.zig").ClientStream.init(
            self.allocator,
            &self.ring,
            &self.io_registry,
            on_data,
            on_close,
            callback_ctx,
            &self.dns_resolver,
        );
    }

    fn nextUserData(self: *Self) u64 {
        const id = self.next_user_data;
        self.next_user_data +%= 1;
        var ud = id & ~ACCEPT_USER_DATA;
        if (ud == 0) ud = 1;
        return ud;
    }

    fn nextConnId(self: *Self) u64 {
        const id = self.next_conn_id;
        self.next_conn_id +%= 1;
        return id;
    }

    fn allocFixedIndex(self: *Self) !u16 {
        if (self.fixed_file_freelist.pop()) |idx| return idx;
        if (self.fixed_file_next < MAX_FIXED_FILES) {
            const idx = self.fixed_file_next;
            self.fixed_file_next += 1;
            return idx;
        }
        return error.OutOfFixedFileSlots;
    }

    fn freeFixedIndex(self: *Self, idx: u16) void {
        self.fixed_file_freelist.append(self.allocator, idx) catch |err| {
            logErr("freeFixedIndex: append failed for idx {d}: {s}", .{ idx, @errorName(err) });
        };
    }

    fn submitAccept(self: *Self) !void {
        var addr: linux.sockaddr = undefined;
        var addrlen: u32 = @sizeOf(linux.sockaddr);
        _ = try self.ring.accept(ACCEPT_USER_DATA, @intCast(self.listen_fd), &addr, &addrlen, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    }

    fn submitRead(self: *Self, conn_id: u64, conn: *Connection) !void {
        const user_data = conn_id;
        const fd = if (self.use_fixed_files) @as(i32, @intCast(conn.fixed_index)) else conn.fd;
        const sqe = try self.ring.read(user_data, fd, .{
            .buffer_selection = .{ .group_id = READ_BUF_GROUP_ID, .len = BUFFER_SIZE },
        }, 0);
        if (self.use_fixed_files) sqe.flags |= linux.IOSQE_FIXED_FILE;
    }

    fn submitWrite(self: *Self, conn_id: u64, conn: *Connection) !void {
        conn.write_start_ms = milliTimestamp(self.io);
        const user_data = conn_id;
        const fd = if (self.use_fixed_files) @as(i32, @intCast(conn.fixed_index)) else conn.fd;

        const resp_buf = conn.response_buf orelse return;

        if (conn.write_body) |body| {
            const total = conn.write_headers_len + body.len;
            if (conn.write_offset >= total) return;

            var iovs: [2]std.posix.iovec_const = undefined;
            var count: usize = 0;

            if (conn.write_offset < conn.write_headers_len) {
                iovs[count] = .{
                    .base = resp_buf.ptr + conn.write_offset,
                    .len = conn.write_headers_len - conn.write_offset,
                };
                count += 1;
            }

            const body_start = if (conn.write_offset > conn.write_headers_len)
                conn.write_offset - conn.write_headers_len
            else
                0;
            if (body_start < body.len) {
                iovs[count] = .{
                    .base = body.ptr + body_start,
                    .len = body.len - body_start,
                };
                count += 1;
            }

            const sqe = try self.ring.writev(user_data, fd, iovs[0..count], 0);
            if (self.use_fixed_files) sqe.flags |= linux.IOSQE_FIXED_FILE;
        } else {
            if (conn.write_offset >= conn.write_headers_len) return;
            const to_send = resp_buf[conn.write_offset..conn.write_headers_len];
            const sqe = try self.ring.write(user_data, fd, to_send, 0);
            if (self.use_fixed_files) sqe.flags |= linux.IOSQE_FIXED_FILE;
        }
    }

    fn closeConn(self: *Self, conn_id: u64, fd: i32) void {
        self.ws_server.removeActive(conn_id);
        // Clean up connection resources regardless of fd validity
        if (self.connections.getPtr(conn_id)) |conn| {
            if (conn.write_body) |b| self.allocator.free(b);
            if (conn.ws_token) |t| self.allocator.free(t);
            if (conn.response_buf) |buf| self.buffer_pool.freeTieredWriteBuf(buf, conn.response_buf_tier);
        }
        if (self.use_fixed_files) {
            if (self.connections.getPtr(conn_id)) |conn| {
                const idx = conn.fixed_index;
                _ = self.ring.register_files_update(idx, &[_]linux.fd_t{-1}) catch {};
                self.freeFixedIndex(idx);
            }
        }
        _ = self.connections.remove(conn_id);
        if (fd > 0) {
            const rc = linux.close(fd);
            if (rc != 0) logErr("close fd={d} failed: {d}", .{ fd, rc });
        }
    }

    fn onAcceptComplete(self: *Self, res: i32, user_data: u64) void {
        _ = user_data;
        if (res < 0) {
            logErr("accept failed: {}", .{res});
            self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        }
        const conn_fd: i32 = @intCast(res);
        const conn_id = self.nextConnId();
        var conn = Connection{
            .id = conn_id,
            .fd = conn_fd,
            .last_active_ms = milliTimestamp(self.io),
        };

        if (self.use_fixed_files) {
            const idx = self.allocFixedIndex() catch {
                const rc = linux.close(conn_fd);
                if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
                self.submitAccept() catch {};
                return;
            };
            if (self.ring.register_files_update(idx, &[_]linux.fd_t{conn_fd})) {
                conn.fixed_index = idx;
            } else |_| {
                self.freeFixedIndex(idx);
                const rc = linux.close(conn_fd);
                if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
                self.submitAccept() catch {};
                return;
            }
        }

        self.connections.put(conn_id, conn) catch {
            if (self.use_fixed_files) {
                const idx = conn.fixed_index;
                _ = self.ring.register_files_update(idx, &[_]linux.fd_t{-1}) catch {};
                self.freeFixedIndex(idx);
            }
            const rc = linux.close(conn_fd);
            if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
            self.submitAccept() catch |err| logErr("failed to resubmit accept after put error: {s}", .{@errorName(err)});
            return;
        };
        const conn_ptr = self.connections.getPtr(conn_id) orelse {
            self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        };
        self.submitRead(conn_id, conn_ptr) catch |err| {
            logErr("submitRead failed for fd {}: {s}", .{ conn_fd, @errorName(err) });
            self.closeConn(conn_id, conn_fd);
            self.submitAccept() catch |err2| logErr("failed to resubmit accept after read error: {s}", .{@errorName(err2)});
            return;
        };
        self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
    }

    fn onReadComplete(self: *Self, conn_id: u64, res: i32, user_data: u64, cqe_flags: u32) void {
        _ = user_data;
        if (res <= 0) {
            const conn = self.connections.get(conn_id) orelse return;
            if (cqe_flags & linux.IORING_CQE_F_BUFFER != 0) {
                const err_bid = @as(u16, @truncate(cqe_flags >> 16));
                self.buffer_pool.markReplenish(err_bid);
            }
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const conn = self.connections.getPtr(conn_id) orelse return;

        if (cqe_flags & linux.IORING_CQE_F_BUFFER == 0) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const bid = @as(u16, @truncate(cqe_flags >> 16));
        const read_buf = self.buffer_pool.getReadBuf(bid);
        const nread = @as(usize, @intCast(res));

        if (conn.read_len > 0) self.buffer_pool.markReplenish(conn.read_bid);
        conn.read_bid = bid;
        conn.read_len = nread;

        const has_header_end = std.mem.indexOf(u8, read_buf[0..nread], "\r\n\r\n") != null or
            std.mem.indexOf(u8, read_buf[0..nread], "\n\n") != null;
        if (!has_header_end) {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 431, "Request Header Fields Too Large");
            return;
        }
        conn.state = .processing;

        conn.keep_alive = isKeepAliveConnection(read_buf[0..nread]);

        const path = getPathFromNextuest(read_buf[0..nread]) orelse {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 400, "Bad Request");
            return;
        };

        if (self.ws_server.hasHandlers() and ws_upgrade.isUpgradeRequest(read_buf[0..nread])) {
            self.tryWsUpgrade(conn_id, conn, path, read_buf[0..nread], bid);
            return;
        }

        if (self.respond_middlewares.has_global or
            self.respond_middlewares.precise.count() > 0 or
            self.respond_middlewares.wildcard.items.len > 0)
        {
            var temp_ctx = Context{
                .request_data = read_buf[0..nread],
                .path = path,
                .app_ctx = self.app_ctx,
                .allocator = self.allocator,
                .status = 200,
                .content_type = .plain,
                .body = null,
                .headers = null,
                .conn_id = conn_id,
                .server = @ptrCast(self),
            };
            defer temp_ctx.deinit();

            if (self.respond_middlewares.has_global) {
                for (self.respond_middlewares.global.items) |mw| {
                    _ = mw(self.allocator, &temp_ctx) catch |err| {
                        logErr("respond middleware error: {s}", .{@errorName(err)});
                        break;
                    };
                    if (temp_ctx.body != null) break;
                }
            }

            if (temp_ctx.body == null) {
                if (self.respond_middlewares.precise.get(path)) |list| {
                    for (list.items) |mw| {
                        _ = mw(self.allocator, &temp_ctx) catch |err| {
                            logErr("respond middleware error: {s}", .{@errorName(err)});
                            break;
                        };
                        if (temp_ctx.body != null) break;
                    }
                }
            }

            if (temp_ctx.body == null) {
                for (self.respond_middlewares.wildcard.items) |entry| {
                    if (entry.rule.match(path)) {
                        for (entry.list.items) |mw| {
                            _ = mw(self.allocator, &temp_ctx) catch |err| {
                                logErr("respond middleware error: {s}", .{@errorName(err)});
                                break;
                            };
                            if (temp_ctx.body != null) break;
                        }
                        if (temp_ctx.body != null) break;
                    }
                }
            }

            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;

            const extra_headers = if (temp_ctx.headers) |h| h.items else "";

            if (temp_ctx.body) |body| {
                if (!self.ensureWriteBuf(conn, 512 + body.len + extra_headers.len)) {
                    self.allocator.free(body);
                    temp_ctx.body = null;
                    self.closeConn(conn_id, conn.fd);
                    return;
                }
                const buf = conn.response_buf.?;
                const mime = switch (temp_ctx.content_type) {
                    .plain => "text/plain",
                    .json => "application/json",
                    .html => "text/html",
                };
                const reason = statusText(temp_ctx.status);
                const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
                const len = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ temp_ctx.status, reason, mime, extra_headers, body.len, conn_hdr, body }) catch {
                    self.respondError(conn);
                    return;
                };
                conn.write_headers_len = len.len;
                conn.write_offset = 0;
                conn.write_body = null;
                conn.state = .writing;
                self.submitWrite(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
            } else if (extra_headers.len > 0) {
                if (!self.ensureWriteBuf(conn, 256 + extra_headers.len)) {
                    self.closeConn(conn_id, conn.fd);
                    return;
                }
                const buf = conn.response_buf.?;
                const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
                const len = std.fmt.bufPrint(buf, "HTTP/1.1 200 OK\r\n{s}Content-Length: 0\r\nConnection: {s}\r\n\r\n", .{ extra_headers, conn_hdr }) catch {
                    self.respondError(conn);
                    return;
                };
                conn.write_headers_len = len.len;
                conn.write_offset = 0;
                conn.state = .writing;
                self.submitWrite(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
            } else {
                self.respond(conn, 200, "OK");
            }
            return;
        }

        const has_async = self.middlewares.has_global or
            self.middlewares.precise.count() > 0 or
            self.middlewares.wildcard.items.len > 0 or
            self.handlers.count() > 0;
        if (has_async) {
            const selected_buf = self.buffer_pool.getReadBuf(conn.read_bid);
            const read_len = conn.read_len;
            const method_str = getMethodFromNextuest(selected_buf[0..read_len]) orelse "GET";

            const t = self.http_ctx_pool.create(self.allocator) catch {
                self.respond(conn, 500, "Internal Server Error");
                return;
            };
            const method_cap: u4 = @intCast(@min(method_str.len, 15));
            const path_cap: u8 = @intCast(@min(path.len, 255));
            t.* = .{
                .tag = 0x48540001,
                .server = self,
                .conn_id = conn_id,
                .read_bid = conn.read_bid,
                .method_len = method_cap,
                .path_len = path_cap,
                .request_data = selected_buf[0..read_len],
            };
            @memcpy(t.method_buf[0..method_cap], method_str[0..method_cap]);
            @memcpy(t.path_buf[0..path_cap], path[0..path_cap]);

            var fiber = Fiber.init(self.shared_fiber_stack);
            fiber.exec(.{
                .userCtx = t,
                .complete = httpTaskComplete,
                .execFn = httpTaskExec,
            });

            conn.read_len = 0;
            return;
        }

        self.buffer_pool.markReplenish(conn.read_bid);
        conn.read_len = 0;
        self.respond(conn, 404, "Not Found");
    }

    fn onWriteComplete(self: *Self, conn_id: u64, res: i32, user_data: u64) void {
        _ = user_data;
        if (res <= 0) {
            const conn = self.connections.get(conn_id) orelse return;
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const conn = self.connections.getPtr(conn_id) orelse return;
        conn.write_offset += @as(usize, @intCast(res));
        const total = conn.write_headers_len + if (conn.write_body) |b| b.len else 0;
        if (conn.write_offset >= total) {
            if (conn.write_body) |b| {
                self.allocator.free(b);
                conn.write_body = null;
            }
            conn.write_start_ms = 0;
            if (conn.response_buf) |buf| {
                self.buffer_pool.freeTieredWriteBuf(buf, conn.response_buf_tier);
                conn.response_buf = null;
            }
            if (self.ws_server.getActive(conn_id) != null) {
                conn.write_offset = 0;
                conn.write_headers_len = 0;
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch |err| {
                    logErr("submitRead failed for WS upgrade fd {}: {s}", .{ conn.fd, @errorName(err) });
                    self.closeConn(conn_id, conn.fd);
                };
            } else if (conn.keep_alive) {
                conn.write_start_ms = 0;
                conn.state = .reading;
                conn.read_len = 0;
                conn.write_offset = 0;
                conn.write_headers_len = 0;
                conn.last_active_ms = milliTimestamp(self.io);
                self.submitRead(conn_id, conn) catch |err| {
                    logErr("submitRead failed for keep-alive fd {}: {s}", .{ conn.fd, @errorName(err) });
                    self.closeConn(conn_id, conn.fd);
                };
            } else {
                self.closeConn(conn_id, conn.fd);
            }
        } else {
            self.submitWrite(conn_id, conn) catch |err| {
                logErr("submitWrite failed for fd {}: {s}", .{ conn.fd, @errorName(err) });
                self.closeConn(conn_id, conn.fd);
            };
        }
    }

    pub fn getConnToken(self: *Self, conn_id: u64) ?[]const u8 {
        if (self.connections.getPtr(conn_id)) |conn| {
            return conn.ws_token;
        }
        return null;
    }

    pub fn registerSubmitQueue(self: *Self, queue: *uring_submit.SubmitQueue) !void {
        try self.submit_registry.register(queue);
    }

    pub fn initPool4NextSubmit(self: *Self, worker_count: u8) !void {
        self.ensureNext();
        try self.next.?.initPool4NextSubmit(worker_count);
    }

    pub fn stop(self: *Self) void {
        self.should_stop = true;
    }

    pub fn run(self: *Self) !void {
        if (self.cfg.io_cpu) |cpu| {
            var mask: linux.cpu_set_t = [_]usize{0} ** (linux.CPU_SETSIZE / @sizeOf(usize));
            mask[0] = @as(usize, 1) << @as(u6, cpu);
            var orig_mask: linux.cpu_set_t = undefined;
            _ = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &orig_mask);
            self.worker_orig_cpu_mask = orig_mask[0];
            self.io_pinned = if (linux.sched_setaffinity(0, &mask)) true else |_| false;
        }

        try self.submitAccept();

        var cqes: [MAX_CQES_BATCH]linux.io_uring_cqe = undefined;
        var user_tasks_buf: [USER_TASK_BATCH]Item = undefined;
        while (!self.should_stop) {
            try self.buffer_pool.flushReplenish(&self.ring);

            // 提交待处理的 SQE（可能来自上轮处理的 submitRead/submitWrite）
            _ = self.ring.submit() catch |err| {
                logErr("submit failed: {s}", .{@errorName(err)});
            };

            // 非阻塞收割
            const n = try self.ring.copy_cqes(&cqes, 0);
            if (n > 0) {
                // 高速路径: 有事件就处理，不阻塞
                self.dispatchCqes(&cqes, n);
                // Next.go() 任务: 同一线程 fiber 执行
                self.drainNextTasks();
                // tick 钩子: 每轮必触发（倒计时、超时检测等）
                self.drainTick();
                // worker 线程异步回调
                self.drainDeferred();
                // 处理中可能产生新 SQE → 下一轮 submit 带出去
                continue;
            }

            // 低速路径: 没事做，补 timeout/用户任务
            if (self.timeout_user_data == 0) {
                self.submitIdleTimeout() catch |err| {
                    logErr("submitIdleTimeout failed: {s}", .{@errorName(err)});
                };
            }

            {
                const n_user = self.submit_registry.drain(&user_tasks_buf);
                for (user_tasks_buf[0..n_user]) |*req| {
                    self.executeNext(req);
                }
            }

            // Next.go() 任务
            self.drainNextTasks();
            // tick 钩子: 每轮必触发
            self.drainTick();
            self.drainDeferred();

            // 提交 + 阻塞等至少 1 个完成事件
            _ = try self.ring.submit_and_wait(1);
            const n2 = try self.ring.copy_cqes(&cqes, 0);
            self.dispatchCqes(&cqes, n2);
        }
    }

    fn dispatchCqes(self: *Self, cqes: []linux.io_uring_cqe, n: usize) void {
        for (cqes[0..n], 0..) |cqe, i| {
            const user_data = cqe.user_data;
            const res = cqe.res;

            if (self.timeout_user_data != 0 and user_data == self.timeout_user_data) {
                self.timeout_user_data = 0;
                self.checkIdleConnections();
                self.ring.cqe_seen(&cqes[i]);
                continue;
            }

            if (user_data == ACCEPT_USER_DATA) {
                self.ring.cqe_seen(&cqes[i]);
                self.onAcceptComplete(res, user_data);
            } else if ((user_data & DNS_USER_DATA_FLAG) != 0) {
                defer self.ring.cqe_seen(&cqes[i]);
                self.dns_resolver.handleCqe(res);
            } else if ((user_data & CLIENT_USER_DATA_FLAG) != 0) {
                defer self.ring.cqe_seen(&cqes[i]);
                self.io_registry.dispatch(user_data, res);
            } else {
                const conn_id = user_data;
                const conn = self.connections.getPtr(conn_id) orelse {
                    self.ring.cqe_seen(&cqes[i]);
                    continue;
                };
                defer self.ring.cqe_seen(&cqes[i]);

                if (conn.state == .reading or conn.state == .processing) {
                    self.onReadComplete(conn_id, res, user_data, cqe.flags);
                } else if (conn.state == .writing) {
                    self.onWriteComplete(conn_id, res, user_data);
                } else if (conn.state == .ws_reading) {
                    self.onWsFrame(conn_id, res, user_data, cqe.flags);
                } else if (conn.state == .ws_writing) {
                    self.onWsWriteComplete(conn_id, res, user_data);
                } else {
                    self.closeConn(conn_id, conn.fd);
                }
            }
        }
    }

    fn drainNextTasks(self: *Self) void {
        if (self.next) |*n| {
            while (n.ringbuffer.pop()) |item| {
                self.executeNext(&item);
            }
        }
    }

    /// 消费用户 Next，调 execute。
    fn executeNext(self: *Self, req: *const Item) void {
        _ = self;
        pending_user_item = req;
        defer pending_user_item = null;
        req.execute(req.ctx, executeUserComplete);
    }

    fn submitIdleTimeout(self: *Self) !void {
        const user_data = self.nextUserData();
        _ = self.ring.timeout(user_data, &self.timeout_ts, 0, 0) catch {
            self.timeout_user_data = 0;
            return;
        };
        self.timeout_user_data = user_data;
    }

    fn checkIdleConnections(self: *Self) void {
        const now = milliTimestamp(self.io);
        var to_remove = std.ArrayList(u64).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr;
            if (conn.state == .reading and conn.last_active_ms > 0) {
                const idle_ms = now - conn.last_active_ms;
                if (idle_ms >= @as(i64, @intCast(self.cfg.idle_timeout_ms))) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
            if (conn.state == .writing and conn.write_start_ms > 0) {
                const write_ms = now - conn.write_start_ms;
                if (write_ms >= @as(i64, @intCast(self.cfg.write_timeout_ms))) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
        }

        for (to_remove.items) |conn_id| {
            logErr("closing idle connection conn_id={d}", .{conn_id});
            if (self.connections.getPtr(conn_id)) |conn| {
                self.closeConn(conn_id, conn.fd);
            }
        }
    }

    fn ensureWriteBuf(self: *Self, conn: *Connection, min_size: usize) bool {
        if (conn.response_buf) |existing| {
            if (existing.len >= min_size) return true;
            self.buffer_pool.freeTieredWriteBuf(existing, conn.response_buf_tier);
            conn.response_buf = null;
        }
        if (self.buffer_pool.allocTieredWriteBuf(min_size)) |a| {
            conn.response_buf = a.buf;
            conn.response_buf_tier = @intCast(a.tier);
            return true;
        }
        return false;
    }

    pub fn respond(self: *Self, conn: *Connection, status: u16, text: []const u8) void {
        if (!self.ensureWriteBuf(conn, 256)) {
            self.closeConn(conn.id, conn.fd);
            return;
        }
        const buf = conn.response_buf.?;
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{ status, text, conn_hdr }) catch {
            self.respondError(conn);
            return;
        };
        conn.write_headers_len = len.len;
        conn.write_offset = 0;
        conn.write_body = null;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn respondWithHeader(self: *Self, conn: *Connection, status: u16, text: []const u8, extra_headers: []const u8) void {
        if (!self.ensureWriteBuf(conn, 512)) {
            self.closeConn(conn.id, conn.fd);
            return;
        }
        const buf = conn.response_buf.?;
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\n{s}Content-Length: 0\r\nConnection: {s}\r\n\r\n", .{ status, text, extra_headers, conn_hdr }) catch {
            self.respondError(conn);
            return;
        };
        conn.write_headers_len = len.len;
        conn.write_offset = 0;
        conn.write_body = null;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn respondJson(self: *Self, conn: *Connection, status: u16, json_body: []const u8) void {
        const needed = 256 + json_body.len;
        if (!self.ensureWriteBuf(conn, needed)) {
            self.closeConn(conn.id, conn.fd);
            return;
        }
        const buf = conn.response_buf.?;
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const reason = statusText(status);
        const len = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ status, reason, json_body.len, conn_hdr, json_body }) catch {
            self.respondError(conn);
            return;
        };
        conn.write_headers_len = len.len;
        conn.write_offset = 0;
        conn.write_body = null;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn respondError(self: *Self, conn: *Connection) void {
        if (!self.ensureWriteBuf(conn, 256)) {
            self.closeConn(conn.id, conn.fd);
            return;
        }
        const buf = conn.response_buf.?;
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(buf, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{conn_hdr}) catch {
            self.closeConn(conn.id, conn.fd);
            return;
        };
        conn.write_headers_len = len.len;
        conn.write_offset = 0;
        conn.write_body = null;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn respondZeroCopy(self: *Self, conn: *Connection, status: u16, content_type: Context.ContentType, body: []u8, extra_headers: []const u8) void {
        if (!self.ensureWriteBuf(conn, 512 + extra_headers.len)) {
            self.allocator.free(body);
            self.closeConn(conn.id, conn.fd);
            return;
        }
        const buf = conn.response_buf.?;
        const mime = switch (content_type) {
            .plain => "text/plain",
            .json => "application/json",
            .html => "text/html",
        };
        const reason = statusText(status);
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nConnection: {s}\r\n\r\n", .{ status, reason, mime, extra_headers, body.len, conn_hdr }) catch {
            self.allocator.free(body);
            self.respondError(conn);
            return;
        };
        conn.write_headers_len = len.len;
        conn.write_body = body;
        conn.write_offset = 0;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            if (conn.write_body) |b| self.allocator.free(b);
            conn.write_body = null;
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn sendDeferredResponse(self: *Self, conn_id: u64, status: u16, ct: Context.ContentType, body: []u8) void {
        const node = self.allocator.create(DeferredNode) catch {
            self.allocator.free(body);
            return;
        };
        node.* = .{ .next = null, .conn_id = conn_id, .status = status, .ct = ct, .body = body };
        var head = @atomicLoad(?*DeferredNode, &self.deferred_head, .monotonic);
        while (true) {
            node.next = head;
            head = @cmpxchgWeak(?*DeferredNode, &self.deferred_head, head, node, .release, .monotonic) orelse break;
        }
    }

    /// 添加 deferred 钩子，在 drainDeferred 发送响应前调用。
    ///
    /// 钩子按注册顺序在 IO 线程执行，可安全访问 IO 线程独占数据。
    ///
    /// **重要提醒：**
    /// - 钩子**不应 panic**（用 log 记录错误）
    /// - **不应保存** `node` 指针引用 — 钩子返回后 node 被销毁
    /// - **不应释放** `node.body` — body 由框架负责释放
    pub fn addHookDeferred(self: *Self, hook: *const fn (self: *Self, node: *DeferredNode) void) !void {
        try self.deferred_hooks.append(self.allocator, hook);
    }

    /// 添加 tick 钩子，每轮 IO 循环必触发（有/无 deferred 节点都跑）。
    ///
    /// 可用于倒计时、超时检测、定期广播等独立于 HTTP 请求的周期性逻辑。
    ///
    /// **重要提醒：**
    /// - 钩子**不应 panic**（用 log 记录错误）
    /// - tick 钩子在 IO 线程执行，应保持轻量（不做重计算，可用 Next.submit 卸货）
    pub fn addHookTick(self: *Self, hook: *const fn (self: *Self) void) !void {
        try self.tick_hooks.append(self.allocator, hook);
    }

    fn drainTick(self: *Self) void {
        self.dns_resolver.tick();
        self.invoke_queue.drain(self.allocator);
        for (self.tick_hooks.items) |hook| {
            hook(self);
        }
    }

    fn drainDeferred(self: *Self) void {
        const head = @atomicRmw(?*DeferredNode, &self.deferred_head, .Xchg, null, .acquire);
        var node = head;
        while (node) |n| {
            defer {
                const next = n.next;
                self.allocator.destroy(n);
                node = next;
            }
            for (self.deferred_hooks.items) |hook| {
                hook(self, n);
            }
            if (self.connections.getPtr(n.conn_id)) |conn| {
                self.respondZeroCopy(conn, n.status, n.ct, n.body, "");
            } else {
                self.allocator.free(n.body);
            }
        }
    }

    fn tryWsUpgrade(self: *Self, conn_id: u64, conn: *Connection, path: []const u8, data: []const u8, bid: u16) void {
        const full_uri = helpers.getFullUri(data);
        if (full_uri) |uri| {
            if (helpers.extractQueryParam(uri, "token")) |token| {
                conn.ws_token = self.allocator.dupe(u8, token) catch null;
            }
        }

        const handler = self.ws_server.getHandler(path) orelse {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 404, "Not Found");
            return;
        };

        const ws_key = ws_upgrade.extractWsKey(data) orelse {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 400, "Bad Request");
            return;
        };

        // RFC 6455: Sec-WebSocket-Key is base64(16 bytes) = 24 chars
        if (ws_key.len > 96) {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 400, "Bad Request");
            return;
        }

        var accept_buf: [29]u8 = undefined;
        ws_upgrade.computeAcceptKey(ws_key, &accept_buf) catch {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 400, "Bad Request");
            return;
        };
        if (!self.ensureWriteBuf(conn, 256)) {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 500, "Internal Server Error");
            return;
        }
        const upgrade_buf = conn.response_buf.?;
        const len = ws_upgrade.buildUpgradeResponse(upgrade_buf, accept_buf[0..28]) catch {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 500, "Internal Server Error");
            return;
        };

        self.ws_server.addActive(conn_id, handler) catch {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 500, "Internal Server Error");
            return;
        };

        self.buffer_pool.markReplenish(bid);
        conn.read_len = 0;
        conn.keep_alive = false;
        conn.write_headers_len = len;
        conn.write_offset = 0;
        conn.state = .writing;
        // The response buffer already has the upgrade response.
        // onWriteComplete will detect ws_writing_complete by checking ws_active.
        self.submitWrite(conn_id, conn) catch {
            self.closeConn(conn_id, conn.fd);
        };
    }

    fn onWsFrame(self: *Self, conn_id: u64, res: i32, user_data: u64, cqe_flags: u32) void {
        _ = user_data;
        if (res <= 0) {
            const conn = self.connections.get(conn_id) orelse return;
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const conn = self.connections.getPtr(conn_id) orelse return;

        if (cqe_flags & linux.IORING_CQE_F_BUFFER == 0) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const bid = @as(u16, @truncate(cqe_flags >> 16));
        const read_buf = self.buffer_pool.getReadBuf(bid);
        const nread = @as(usize, @intCast(res));

        if (conn.read_len > 0) self.buffer_pool.markReplenish(conn.read_bid);
        conn.read_bid = bid;
        conn.read_len = nread;

        const frame = ws_frame.parseFrame(read_buf[0..nread]) catch {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.closeConn(conn_id, conn.fd);
            return;
        };

        switch (frame.opcode) {
            .close => {
                var close_buf: [32]u8 = undefined;
                const close_len = ws_frame.writeFrame(&close_buf, .{
                    .opcode = .close,
                    .fin = true,
                    .payload = frame.payload,
                }) catch {
                    self.buffer_pool.markReplenish(bid);
                    conn.read_len = 0;
                    self.closeConn(conn_id, conn.fd);
                    return;
                };
                self.buffer_pool.markReplenish(bid);
                conn.read_len = 0;
                if (self.ensureWriteBuf(conn, close_len)) {
                    const wbuf = conn.response_buf.?;
                    @memcpy(wbuf[0..close_len], close_buf[0..close_len]);
                    conn.write_headers_len = close_len;
                    conn.write_offset = 0;
                    conn.state = .ws_writing;
                    self.submitWrite(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                } else {
                    self.closeConn(conn_id, conn.fd);
                }
            },
            .ping => {
                var pong_buf: [16]u8 = undefined;
                const pong_len = ws_frame.writeFrame(&pong_buf, .{
                    .opcode = .pong,
                    .fin = true,
                    .payload = frame.payload,
                }) catch {
                    self.buffer_pool.markReplenish(bid);
                    conn.read_len = 0;
                    conn.state = .ws_reading;
                    self.submitRead(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                    return;
                };
                self.buffer_pool.markReplenish(bid);
                conn.read_len = 0;
                if (self.ensureWriteBuf(conn, pong_len)) {
                    const wbuf = conn.response_buf.?;
                    @memcpy(wbuf[0..pong_len], pong_buf[0..pong_len]);
                    conn.write_headers_len = pong_len;
                    conn.write_offset = 0;
                    conn.state = .ws_writing;
                    self.submitWrite(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                } else {
                    conn.state = .ws_reading;
                    self.submitRead(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                }
            },
            .pong => {
                self.buffer_pool.markReplenish(bid);
                conn.read_len = 0;
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
            },
            .text, .binary, .continuation => {
                const handler = self.ws_server.getActive(conn_id) orelse {
                    self.buffer_pool.markReplenish(bid);
                    conn.read_len = 0;
                    self.closeConn(conn_id, conn.fd);
                    return;
                };

                var payload_full: []u8 = undefined;
                var payload_tier: u8 = 0;
                if (self.buffer_pool.allocTieredWriteBuf(frame.payload.len)) |a| {
                    @memcpy(a.buf[0..frame.payload.len], frame.payload);
                    payload_full = a.buf;
                    payload_tier = @intCast(a.tier);
                } else {
                    payload_full = self.allocator.dupe(u8, frame.payload) catch {
                        self.buffer_pool.markReplenish(bid);
                        conn.read_len = 0;
                        handler(conn_id, &frame, self.ws_server.ctx);
                        if (conn.state != .ws_writing) {
                            conn.state = .ws_reading;
                            self.submitRead(conn_id, conn) catch {
                                self.closeConn(conn_id, conn.fd);
                            };
                        }
                        return;
                    };
                    payload_tier = 0xFF; // sentinel: fallback allocator
                }

                var frame_copy = frame;
                frame_copy.payload = payload_full[0..frame.payload.len];

                const t = self.ws_ctx_pool.create(self.allocator) catch {
                    self.buffer_pool.freeTieredWriteBuf(payload_full, payload_tier);
                    handler(conn_id, &frame, self.ws_server.ctx);
                    if (conn.state != .ws_writing) {
                        conn.state = .ws_reading;
                        self.submitRead(conn_id, conn) catch {
                            self.closeConn(conn_id, conn.fd);
                        };
                    }
                    return;
                };
                t.* = .{
                    .tag = 0x57530001,
                    .server = self,
                    .conn_id = conn_id,
                    .read_bid = bid,
                    .payload_tier = payload_tier,
                    .handler = handler,
                    .frame = frame_copy,
                    .payload_buf = payload_full,
                };

                var ws_fiber = Fiber.init(self.shared_fiber_stack);
                ws_fiber.exec(.{
                    .userCtx = t,
                    .complete = wsTaskComplete,
                    .execFn = wsTaskExec,
                });

                if (conn.state != .ws_writing) {
                    conn.state = .ws_reading;
                    self.submitRead(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                }
            },
        }
    }

    fn onWsWriteComplete(self: *Self, conn_id: u64, res: i32, user_data: u64) void {
        _ = user_data;
        if (res <= 0) {
            const conn = self.connections.get(conn_id) orelse return;
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const conn = self.connections.getPtr(conn_id) orelse return;
        conn.write_offset += @as(usize, @intCast(res));
        if (conn.write_offset >= conn.write_headers_len) {
            if (conn.response_buf) |buf| {
                self.buffer_pool.freeTieredWriteBuf(buf, conn.response_buf_tier);
                conn.response_buf = null;
            }
            conn.write_offset = 0;
            conn.write_headers_len = 0;
            conn.state = .ws_reading;
            self.submitRead(conn_id, conn) catch {
                self.closeConn(conn_id, conn.fd);
            };
        } else {
            self.submitWrite(conn_id, conn) catch {
                self.closeConn(conn_id, conn.fd);
            };
        }
    }

    fn wsSendFn(ctx: *anyopaque, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx)));
        try self.sendWsFrame(conn_id, opcode, payload);
    }

    pub fn sendWsFrame(self: *Self, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
        const conn = self.connections.getPtr(conn_id) orelse return;
        if (conn.state != .ws_reading) return;
        const total = ws_frame.frameSize(payload.len);
        if (!self.ensureWriteBuf(conn, total)) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const wbuf = conn.response_buf.?;
        if (total > wbuf.len) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        _ = ws_frame.writeFrame(wbuf, .{
            .opcode = opcode,
            .fin = true,
            .payload = payload,
        }) catch {
            self.closeConn(conn_id, conn.fd);
            return;
        };
        conn.write_headers_len = total;
        conn.write_offset = 0;
        conn.state = .ws_writing;
        self.submitWrite(conn_id, conn) catch {
            self.closeConn(conn_id, conn.fd);
        };
    }
};

/// ── WS 帧 fiber 处理 ─────────────────────────────────────
const WsTaskCtx = struct {
    tag: u32,
    server: *AsyncServer,
    conn_id: u64,
    read_bid: u16 = 0,
    payload_tier: u8 = 0,
    handler: WsHandler,
    frame: ws_frame.Frame,
    payload_buf: []u8,
};

fn wsTaskExec(caller_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
    const t: *WsTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x57530001);
    t.handler(t.conn_id, &t.frame, t.server.ws_server.ctx);
    complete(t, "");
}

fn wsTaskComplete(caller_ctx: ?*anyopaque, _: []const u8) void {
    const t: *WsTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x57530001);
    t.server.buffer_pool.freeTieredWriteBuf(t.payload_buf, t.payload_tier);
    t.server.buffer_pool.markReplenish(t.read_bid);
    if (t.server.connections.getPtr(t.conn_id)) |conn| {
        conn.read_len = 0;
    }
    t.server.ws_ctx_pool.destroy(t);
}

/// ── HTTP 请求 Next 处理 ──────────────────────────────────
const HttpTaskCtx = struct {
    tag: u32,
    server: *AsyncServer,
    conn_id: u64,
    read_bid: u16 = 0,
    method_buf: [16]u8 = [_]u8{0} ** 16,
    method_len: u4 = 0,
    path_buf: [256]u8 = [_]u8{0} ** 256,
    path_len: u8 = 0,
    request_data: []u8,
};

fn httpTaskExec(caller_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
    const t: *HttpTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x48540001);
    const server = t.server;

    const method = t.method_buf[0..t.method_len];
    const path = t.path_buf[0..t.path_len];
    const req_data = t.request_data;

    var ctx = Context{
        .request_data = req_data,
        .path = path,
        .app_ctx = server.app_ctx,
        .allocator = server.allocator,
        .status = 200,
        .content_type = .plain,
        .body = null,
        .headers = null,
        .conn_id = t.conn_id,
        .server = @ptrCast(server),
    };
    defer ctx.deinit();

    var handled = false;

    if (server.middlewares.has_global) {
        for (server.middlewares.global.items) |mw| {
            const stop = mw(server.allocator, &ctx) catch |err| {
                logErr("global middleware error: {s}", .{@errorName(err)});
                if (ctx.body == null) ctx.text(500, @errorName(err)) catch {};
                handled = true;
                break;
            };
            if (stop or ctx.body != null) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        if (server.middlewares.precise.get(path)) |list| {
            for (list.items) |mw| {
                const stop = mw(server.allocator, &ctx) catch |err| {
                    logErr("precise middleware error: {s}", .{@errorName(err)});
                    if (ctx.body == null) ctx.text(500, @errorName(err)) catch {};
                    handled = true;
                    break;
                };
                if (stop or ctx.body != null) {
                    handled = true;
                    break;
                }
            }
        }
    }

    if (!handled) {
        for (server.middlewares.wildcard.items) |entry| {
            if (entry.rule.match(path)) {
                for (entry.list.items) |mw| {
                    const stop = mw(server.allocator, &ctx) catch |err| {
                        logErr("wildcard middleware error: {s}", .{@errorName(err)});
                        if (ctx.body == null) ctx.text(500, @errorName(err)) catch {};
                        handled = true;
                        break;
                    };
                    if (stop or ctx.body != null) {
                        handled = true;
                        break;
                    }
                }
                if (handled) break;
            }
        }
    }

    if (!handled) {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ method, path }) catch null;
        if (key) |k| {
            if (server.handlers.get(k)) |handler| {
                handler(server.allocator, &ctx) catch |err| {
                    logErr("handler error: {s}", .{@errorName(err)});
                    ctx.text(500, @errorName(err)) catch {};
                };
            } else {
                ctx.text(404, "Not Found") catch {};
            }
        } else {
            ctx.text(404, "Not Found") catch {};
        }
    }

    if (ctx.deferred) {
        complete(t, "");
        return;
    }

    var headers_str: []u8 = "";
    if (ctx.headers) |list| {
        headers_str = server.allocator.dupe(u8, list.items) catch "";
    }
    defer if (headers_str.len > 0) server.allocator.free(headers_str);

    const response_body = ctx.body orelse {
        logErr("no response body set for conn_id={d}", .{t.conn_id});
        if (server.connections.getPtr(t.conn_id)) |conn| {
            const body = server.allocator.dupe(u8, "no response body set for conn") catch {
                complete(t, "");
                return;
            };
            server.respondZeroCopy(conn, 500, .plain, body, headers_str);
        }
        complete(t, "");
        return;
    };

    if (server.connections.getPtr(t.conn_id)) |conn| {
        server.respondZeroCopy(conn, ctx.status, ctx.content_type, response_body, headers_str);
    } else {
        server.allocator.free(response_body);
    }
    ctx.body = null;
    complete(t, "");
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        101 => "Switching Protocols",
        else => "",
    };
}

fn httpTaskComplete(caller_ctx: ?*anyopaque, _: []const u8) void {
    const t: *HttpTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x48540001);
    t.server.buffer_pool.markReplenish(t.read_bid);
    if (t.server.connections.getPtr(t.conn_id)) |conn| {
        conn.read_len = 0;
    }
    t.server.http_ctx_pool.destroy(t);
}
