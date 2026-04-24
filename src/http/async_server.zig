const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const RingBuffer = @import("../spsc_ringbuffer.zig").RingBuffer;
const BufferPool = @import("../buffer_pool.zig").BufferPool;

const RING_ENTRIES = @import("../constants.zig").RING_ENTRIES;
const TASK_QUEUE_SIZE = @import("../constants.zig").TASK_QUEUE_SIZE;
const RESPONSE_QUEUE_SIZE = @import("../constants.zig").RESPONSE_QUEUE_SIZE;
const BUFFER_POOL_SIZE = @import("../constants.zig").BUFFER_POOL_SIZE;
const READ_BUF_COUNT = @import("../constants.zig").READ_BUF_COUNT;
const MAX_CQES_BATCH = @import("../constants.zig").MAX_CQES_BATCH;
const ACCEPT_USER_DATA = @import("../constants.zig").ACCEPT_USER_DATA;
const MAX_FIXED_FILES = @import("../constants.zig").MAX_FIXED_FILES;
const BUFFER_SIZE = @import("../constants.zig").BUFFER_SIZE;
const READ_BUF_GROUP_ID = @import("../constants.zig").READ_BUF_GROUP_ID;

const PathRule = @import("../antpath.zig").PathRule;

const Connection = @import("connection.zig").Connection;
const Context = @import("context.zig").Context;
const Middleware = @import("types.zig").Middleware;
const Handler = @import("types.zig").Handler;
const Task = @import("tasks.zig").Task;
const ResponseTask = @import("tasks.zig").ResponseTask;
const MiddlewareStore = @import("middleware_store.zig").MiddlewareStore;
const WildcardEntry = @import("middleware_store.zig").WildcardEntry;

const getMethodFromRequest = @import("http_helpers.zig").getMethodFromRequest;
const getPathFromRequest = @import("http_helpers.zig").getPathFromRequest;
const isKeepAliveConnection = @import("http_helpers.zig").isKeepAliveConnection;
const parseIpv4 = @import("http_helpers.zig").parseIpv4;
const logErr = @import("http_helpers.zig").logErr;

const WsServer = @import("../ws/server.zig").WsServer;
const WsHandler = @import("../ws/server.zig").WsHandler;
const Frame = @import("../ws/types.zig").Frame;
const Opcode = @import("../ws/types.zig").Opcode;
const ws_frame = @import("../ws/frame.zig");
const ws_upgrade = @import("../ws/upgrade.zig");
const constants = @import("../constants.zig");

fn milliTimestamp(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @as(i64, @intCast(@divTrunc(ts.nanoseconds, @as(i96, std.time.ns_per_ms))));
}

pub const AsyncServer = struct {
    allocator: Allocator,
    io: std.Io,
    ring: linux.IoUring,
    listen_fd: i32,
    next_conn_id: u64,
    connections: std.AutoHashMap(u64, Connection),
    next_user_data: u64,
    app_ctx: ?*anyopaque,

    task_queue: RingBuffer(Task, TASK_QUEUE_SIZE),
    response_queue: RingBuffer(ResponseTask, RESPONSE_QUEUE_SIZE),

    worker_thread: ?std.Thread = null,
    worker_should_stop: bool = false,
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
        write_buf_count: u32 = constants.WRITE_BUF_COUNT,
        max_fixed_files: u32 = constants.MAX_FIXED_FILES,
        max_path_length: u32 = constants.MAX_PATH_LENGTH,
        idle_timeout_ms: u64 = constants.IDLE_TIMEOUT_MS,
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
        write_buf_count,
        max_fixed_files,
        max_path_length,
        idle_timeout_ms,
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
            .write_buf_count => self.cfg.write_buf_count = @intCast(value),
            .max_fixed_files => self.cfg.max_fixed_files = @intCast(value),
            .max_path_length => self.cfg.max_path_length = @intCast(value),
            .idle_timeout_ms => self.cfg.idle_timeout_ms = @intCast(value),
        }
    }

    pub fn init(allocator: Allocator, io: std.Io, listen_addr: []const u8, app_ctx: ?*anyopaque) !Self {
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
            .port = port,
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

        var bp = try BufferPool.init(allocator, BUFFER_POOL_SIZE, READ_BUF_COUNT);
        errdefer bp.deinit();

        var server = Self{
            .allocator = allocator,
            .io = io,
            .ring = ring,
            .listen_fd = fd,
            .next_conn_id = 1,
            .connections = std.AutoHashMap(u64, Connection).init(allocator),
            .next_user_data = 1,
            .app_ctx = app_ctx,
            .task_queue = RingBuffer(Task, TASK_QUEUE_SIZE).init(),
            .response_queue = RingBuffer(ResponseTask, RESPONSE_QUEUE_SIZE).init(),
            .buffer_pool = bp,
            .use_fixed_files = use_ff,
            .fixed_file_freelist = ff_freelist,
            .fixed_file_next = 0,
            .worker_thread = null,
            .worker_should_stop = false,
            .ws_server = WsServer.init(allocator),
            .middlewares = mw_store,
            .respond_middlewares = respond_mw_store,
            .handlers = std.StringHashMap(Handler).init(allocator),
            .cfg = Config{},
        };
        server.ws_server.parent = @ptrCast(&server);
        try server.buffer_pool.provideAllReads(&server.ring);
        return server;
    }

    pub fn deinit(self: *Self) void {
        if (self.worker_thread) |t| {
            self.worker_should_stop = true;
            t.join();
        }

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.write_body) |b| self.allocator.free(b);
            if (entry.value_ptr.response_buf.len > 0) self.buffer_pool.freeWriteBuf(entry.value_ptr.response_buf);
            _ = linux.close(entry.value_ptr.fd);
        }
        _ = linux.close(self.listen_fd);

        self.connections.deinit();
        self.ring.deinit();
        self.buffer_pool.deinit();
        self.fixed_file_freelist.deinit(self.allocator);
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
    }

    pub fn use(self: *Self, pattern: []const u8, middleware: Middleware) !void {
        if (pattern.len == 0 or (pattern.len == 1 and pattern[0] == '/')) {
            return error.InvalidPattern;
        }
        if ((pattern.len == 3 and pattern[0] == '/' and pattern[1] == '*' and pattern[2] == '*') or
            (pattern.len == 2 and pattern[0] == '*' and pattern[1] == '*'))
        {
            try self.middlewares.global.append(self.allocator, middleware);
            self.middlewares.has_global = true;
            try self.ensureWorkerStarted();
            return;
        }
        if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
            const gop = try self.middlewares.precise.getOrPut(pattern);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Middleware).empty;
            }
            try gop.value_ptr.append(self.allocator, middleware);
            try self.ensureWorkerStarted();
            return;
        }
        for (self.middlewares.wildcard.items) |*entry| {
            if (std.mem.eql(u8, entry.rule.pattern, pattern)) {
                try entry.list.append(self.allocator, middleware);
                try self.ensureWorkerStarted();
                return;
            }
        }
        var rule = try PathRule.init(self.allocator, pattern);
        errdefer rule.deinit();
        var new_list = std.ArrayList(Middleware).empty;
        try new_list.append(self.allocator, middleware);
        try self.middlewares.wildcard.append(self.allocator, .{
            .rule = rule,
            .list = new_list,
        });
        try self.ensureWorkerStarted();
    }

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
            const gop = try self.respond_middlewares.precise.getOrPut(pattern);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Middleware).empty;
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
        var rule = try PathRule.init(self.allocator, pattern);
        errdefer rule.deinit();
        var new_list = std.ArrayList(Middleware).empty;
        try new_list.append(self.allocator, middleware);
        try self.respond_middlewares.wildcard.append(self.allocator, .{
            .rule = rule,
            .list = new_list,
        });
    }

    fn register(self: *Self, method: []const u8, path: []const u8, handler: Handler) !void {
        try self.ensureWorkerStarted();
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ method, path });
        _ = try self.handlers.put(key, handler);
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

    fn ensureWorkerStarted(self: *Self) !void {
        if (self.worker_thread != null) return;
        self.worker_thread = try std.Thread.spawn(.{}, workerThreadEntry, .{self});
    }

    fn nextUserData(self: *Self) u64 {
        const id = self.next_user_data;
        self.next_user_data +%= 1;
        return id & ~ACCEPT_USER_DATA;
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
        self.fixed_file_freelist.append(self.allocator, idx) catch {};
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
        const user_data = conn_id;
        const fd = if (self.use_fixed_files) @as(i32, @intCast(conn.fixed_index)) else conn.fd;

        if (conn.write_body) |body| {
            const total = conn.write_headers_len + body.len;
            if (conn.write_offset >= total) return;

            var iovs: [2]std.posix.iovec_const = undefined;
            var count: usize = 0;

            if (conn.write_offset < conn.write_headers_len) {
                iovs[count] = .{
                    .base = conn.response_buf.ptr + conn.write_offset,
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
            const to_send = conn.response_buf[conn.write_offset..conn.write_headers_len];
            const sqe = try self.ring.write(user_data, fd, to_send, 0);
            if (self.use_fixed_files) sqe.flags |= linux.IOSQE_FIXED_FILE;
        }
    }

    fn closeConn(self: *Self, conn_id: u64, fd: i32) void {
        self.ws_server.removeActive(conn_id);
        if (fd <= 0) return;
        if (self.use_fixed_files) {
            if (self.connections.getPtr(conn_id)) |conn| {
                const idx = conn.fixed_index;
                _ = self.ring.register_files_update(idx, &[_]linux.fd_t{-1}) catch {};
                self.freeFixedIndex(idx);
            }
        }
        _ = linux.close(fd);
        if (self.connections.getPtr(conn_id)) |conn| {
            if (conn.write_body) |b| self.allocator.free(b);
            if (conn.response_buf.len > 0) self.buffer_pool.freeWriteBuf(conn.response_buf);
        }
        _ = self.connections.remove(conn_id);
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
        const write_buf = self.buffer_pool.allocWriteBuf() orelse {
            _ = linux.close(conn_fd);
            self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        };
        var conn = Connection{
            .id = conn_id,
            .fd = conn_fd,
            .response_buf = write_buf,
            .last_active_ms = milliTimestamp(self.io),
        };

        if (self.use_fixed_files) {
            const idx = self.allocFixedIndex() catch {
                _ = linux.close(conn_fd);
                self.buffer_pool.freeWriteBuf(write_buf);
                self.submitAccept() catch {};
                return;
            };
            if (self.ring.register_files_update(idx, &[_]linux.fd_t{conn_fd})) {
                conn.fixed_index = idx;
            } else |_| {
                self.freeFixedIndex(idx);
                _ = linux.close(conn_fd);
                self.buffer_pool.freeWriteBuf(write_buf);
                self.submitAccept() catch {};
                return;
            }
        }

        self.connections.put(conn_id, conn) catch {
            _ = linux.close(conn_fd);
            self.submitAccept() catch |err| logErr("failed to resubmit accept after put error: {s}", .{@errorName(err)});
            return;
        };
        const conn_ptr = self.connections.getPtr(conn_id) orelse return;
        self.submitRead(conn_id, conn_ptr) catch |err| {
            logErr("submitRead failed for fd {}: {s}", .{ conn_fd, @errorName(err) });
            self.closeConn(conn_id, conn_fd);
            self.submitAccept() catch |err2| logErr("failed to resubmit accept after read error: {s}", .{@errorName(err2)});
        };
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

        const path = getPathFromRequest(read_buf[0..nread]) orelse {
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
                const mime = switch (temp_ctx.content_type) {
                    .plain => "text/plain",
                    .json => "application/json",
                    .html => "text/html",
                };
                const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
                const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ temp_ctx.status, mime, extra_headers, body.len, conn_hdr, body }) catch {
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
                const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
                const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 200 OK\r\n{s}Content-Length: 0\r\nConnection: {s}\r\n\r\n", .{ extra_headers, conn_hdr }) catch {
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
            if (self.worker_thread == null) {
                self.respond(conn, 503, "Service Unavailable (worker not started)");
                return;
            }
            const selected_buf = self.buffer_pool.getReadBuf(conn.read_bid);
            const method_str = getMethodFromRequest(selected_buf[0..conn.read_len]) orelse "GET";
            const method_dup = self.allocator.dupe(u8, method_str) catch {
                self.respond(conn, 500, "Internal Server Error");
                return;
            };
            const path_dup = self.allocator.dupe(u8, path) catch {
                self.allocator.free(method_dup);
                self.respond(conn, 500, "Internal Server Error");
                return;
            };
            const request_data_dup = self.allocator.dupe(u8, selected_buf[0..conn.read_len]) catch {
                self.allocator.free(method_dup);
                self.allocator.free(path_dup);
                self.respond(conn, 500, "Internal Server Error");
                return;
            };
            self.buffer_pool.markReplenish(conn.read_bid);
            conn.read_len = 0;
            const task = Task{
                .conn_id = conn_id,
                .method = method_dup,
                .path = path_dup,
                .request_data = request_data_dup,
            };
            if (!self.task_queue.tryPush(task)) {
                self.allocator.free(method_dup);
                self.allocator.free(path_dup);
                self.allocator.free(request_data_dup);
                self.respond(conn, 503, "Service Unavailable");
                return;
            }
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
            if (self.ws_server.getActive(conn_id) != null) {
                conn.write_offset = 0;
                conn.write_headers_len = 0;
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch |err| {
                    logErr("submitRead failed for WS upgrade fd {}: {s}", .{ conn.fd, @errorName(err) });
                    self.closeConn(conn_id, conn.fd);
                };
            } else if (conn.keep_alive) {
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

    pub fn stop(self: *Self) void {
        self.should_stop = true;
    }

    pub fn run(self: *Self) !void {
        try self.submitAccept();

        var cqes: [MAX_CQES_BATCH]linux.io_uring_cqe = undefined;
        while (!self.should_stop) {
            try self.buffer_pool.flushReplenish(&self.ring);

            if (self.timeout_user_data == 0) {
                self.submitIdleTimeout() catch |err| {
                    logErr("submitIdleTimeout failed: {s}", .{@errorName(err)});
                };
            }

            _ = try self.ring.submit_and_wait(1);
            const n = try self.ring.copy_cqes(&cqes, 0);
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

            while (self.response_queue.tryPop()) |resp| {
                const conn = self.connections.getPtr(resp.conn_id) orelse {
                    self.allocator.free(resp.body);
                    self.allocator.free(resp.headers);
                    continue;
                };
                self.respondZeroCopy(conn, resp.status, resp.content_type, resp.body, resp.headers);
                self.allocator.free(resp.headers);
            }
        }
    }

    fn submitIdleTimeout(self: *Self) !void {
        const user_data = self.nextUserData();
        _ = try self.ring.timeout(user_data, &self.timeout_ts, 0, 0);
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
        }

        for (to_remove.items) |conn_id| {
            logErr("closing idle connection conn_id={d}", .{conn_id});
            if (self.connections.getPtr(conn_id)) |conn| {
                self.closeConn(conn_id, conn.fd);
            }
        }
    }

    pub fn respond(self: *Self, conn: *Connection, status: u16, text: []const u8) void {
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{ status, text, conn_hdr }) catch {
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
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 {d} {s}\r\n{s}Content-Length: 0\r\nConnection: {s}\r\n\r\n", .{ status, text, extra_headers, conn_hdr }) catch {
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
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ status, json_body.len, conn_hdr, json_body }) catch {
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
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{conn_hdr}) catch return;
        conn.write_headers_len = len.len;
        conn.write_offset = 0;
        conn.write_body = null;
        conn.state = .writing;
        self.submitWrite(conn.id, conn) catch {
            self.closeConn(conn.id, conn.fd);
        };
    }

    pub fn respondZeroCopy(self: *Self, conn: *Connection, status: u16, content_type: Context.ContentType, body: []u8, extra_headers: []const u8) void {
        const mime = switch (content_type) {
            .plain => "text/plain",
            .json => "application/json",
            .html => "text/html",
        };
        const conn_hdr = if (conn.keep_alive) "keep-alive" else "close";
        const len = std.fmt.bufPrint(conn.response_buf, "HTTP/1.1 {d} OK\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nConnection: {s}\r\n\r\n", .{ status, mime, extra_headers, body.len, conn_hdr }) catch {
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

    fn tryWsUpgrade(self: *Self, conn_id: u64, conn: *Connection, path: []const u8, data: []const u8, bid: u16) void {
        const entry = self.ws_server.getHandler(path) orelse {
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

        var accept_buf: [29]u8 = undefined;
        ws_upgrade.computeAcceptKey(ws_key, &accept_buf);
        const len = ws_upgrade.buildUpgradeResponse(conn.response_buf, accept_buf[0..28]) catch {
            self.buffer_pool.markReplenish(bid);
            conn.read_len = 0;
            self.respond(conn, 500, "Internal Server Error");
            return;
        };

        self.ws_server.addActive(conn_id, entry.handler) catch {
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

        self.buffer_pool.markReplenish(bid);
        conn.read_len = 0;

        switch (frame.opcode) {
            .close => {
                var close_buf: [32]u8 = undefined;
                const close_len = ws_frame.writeFrame(&close_buf, .{
                    .opcode = .close,
                    .fin = true,
                    .payload = frame.payload,
                }) catch {
                    self.closeConn(conn_id, conn.fd);
                    return;
                };
                if (close_len <= conn.response_buf.len) {
                    @memcpy(conn.response_buf[0..close_len], close_buf[0..close_len]);
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
                    conn.state = .ws_reading;
                    self.submitRead(conn_id, conn) catch {
                        self.closeConn(conn_id, conn.fd);
                    };
                    return;
                };
                if (pong_len <= conn.response_buf.len) {
                    @memcpy(conn.response_buf[0..pong_len], pong_buf[0..pong_len]);
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
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
            },
            .text, .binary, .continuation => {
                const active = self.ws_server.getActive(conn_id) orelse {
                    self.closeConn(conn_id, conn.fd);
                    return;
                };
                active.handler(conn_id, &frame, &self.ws_server);

                if (conn.state == .ws_writing) {
                    return;
                }
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
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

    pub fn sendWsFrame(self: *Self, conn_id: u64, opcode: Opcode, payload: []const u8) void {
        const conn = self.connections.getPtr(conn_id) orelse return;
        const total = ws_frame.frameSize(payload.len);
        if (total > conn.response_buf.len) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        ws_frame.writeFrame(conn.response_buf, .{
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

fn workerThreadEntry(server: *AsyncServer) void {
    while (!server.worker_should_stop) {
        if (server.task_queue.tryPop()) |task| {
            defer {
                server.allocator.free(task.method);
                server.allocator.free(task.path);
                server.allocator.free(task.request_data);
            }

            var ctx = Context{
                .request_data = task.request_data,
                .path = task.path,
                .app_ctx = server.app_ctx,
                .allocator = server.allocator,
                .status = 200,
                .content_type = .plain,
                .body = null,
                .headers = null,
            };
            defer ctx.deinit();

            var handled = false;

            if (server.middlewares.has_global) {
                for (server.middlewares.global.items) |mw| {
                    const stop = mw(server.allocator, &ctx) catch |err| {
                        logErr("global middleware error: {s}", .{@errorName(err)});
                        if (ctx.body == null) {
                            ctx.text(500, @errorName(err)) catch {};
                        }
                        break;
                    };
                    if (stop or ctx.body != null) {
                        handled = true;
                        break;
                    }
                }
            }

            if (!handled) {
                if (server.middlewares.precise.get(task.path)) |list| {
                    for (list.items) |mw| {
                        const stop = mw(server.allocator, &ctx) catch |err| {
                            logErr("precise middleware error: {s}", .{@errorName(err)});
                            if (ctx.body == null) {
                                ctx.text(500, @errorName(err)) catch {};
                            }
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
                    if (entry.rule.match(task.path)) {
                        for (entry.list.items) |mw| {
                            const stop = mw(server.allocator, &ctx) catch |err| {
                                logErr("wildcard middleware error: {s}", .{@errorName(err)});
                                if (ctx.body == null) {
                                    ctx.text(500, @errorName(err)) catch {};
                                }
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
                const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ task.method, task.path }) catch null;
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

            var headers_str: []u8 = "";
            if (ctx.headers) |list| {
                headers_str = server.allocator.dupe(u8, list.items) catch "";
            }

            const response_body = ctx.body orelse {
                logErr("no response body set for conn_id={d}", .{task.conn_id});
                const resp = ResponseTask{
                    .conn_id = task.conn_id,
                    .status = 500,
                    .content_type = .plain,
                    .body = server.allocator.dupe(u8, "no response body set for conn") catch continue,
                    .headers = headers_str,
                };
                _ = server.response_queue.tryPush(resp);
                continue;
            };

            const resp = ResponseTask{
                .conn_id = task.conn_id,
                .status = ctx.status,
                .content_type = ctx.content_type,
                .body = response_body,
                .headers = headers_str,
            };
            if (!server.response_queue.tryPush(resp)) {
                server.allocator.free(response_body);
                if (headers_str.len > 0) server.allocator.free(headers_str);
            }
            ctx.body = null;
        } else {
            std.Io.sleep(server.io, std.Io.Duration.fromMicroseconds(100), .awake) catch |err| {
                logErr("sleep failed: {s}", .{@errorName(err)});
            };
        }
    }
}
