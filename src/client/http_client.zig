const std = @import("std");
const Allocator = std.mem.Allocator;

const RingB = @import("ring.zig").RingB;
const RingSharedClient = @import("../shared/tcp_stream.zig").RingSharedClient;
const TinyCache = @import("tiny_cache.zig").TinyCache;
const Pipe = @import("../next/pipe.zig").Pipe;
const Fiber = @import("../next/fiber.zig").Fiber;

pub const Response = struct {
    status: u16,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        // Guard: a zero-length body may be a compile-time constant from the
        // makeErrorResponse triple-fallback path. Only free heap-allocated bodies.
        if (self.body.len > 0) self.allocator.free(self.body);
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) return error.TlsNotSupported;
    if (std.mem.startsWith(u8, rest, "http://")) rest = rest["http://".len..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = if (path_start) |p| rest[0..p] else rest;
    const path = if (path_start) |p| rest[p..] else "/";
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |c| host_port[0..c] else host_port;
    const port: u16 = if (colon) |c| std.fmt.parseInt(u16, host_port[c + 1 ..], 10) catch 80 else 80;
    return .{ .host = try allocator.dupe(u8, host), .port = port, .path = path };
}

fn parseResponse(allocator: Allocator, data: []const u8) !Response {
    const total_len = (try responseCompleteLen(data)) orelse return error.IncompleteResponse;
    const bounds = findHeaderEnd(data[0..total_len]) orelse return error.InvalidResponse;
    const first_line_end = std.mem.indexOfScalar(u8, data, '\r') orelse
        std.mem.indexOfScalar(u8, data, '\n') orelse
        return error.InvalidResponse;
    var status: u16 = 0;
    var parts = std.mem.splitScalar(u8, data[0..first_line_end], ' ');
    _ = parts.next();
    if (parts.next()) |code| status = std.fmt.parseInt(u16, code, 10) catch 500;
    const body_start = bounds.header_end + bounds.sep_len;
    const body = try allocator.dupe(u8, data[body_start..total_len]);
    return .{ .status = status, .body = body, .allocator = allocator };
}

const HeaderBounds = struct {
    header_end: usize,
    sep_len: usize,
};

fn findHeaderEnd(data: []const u8) ?HeaderBounds {
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        return .{ .header_end = pos, .sep_len = 4 };
    }
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return .{ .header_end = pos, .sep_len = 2 };
    }
    return null;
}

fn getHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, name)) {
            const after = line[name.len..];
            if (after.len > 0 and after[0] == ':') {
                return std.mem.trim(u8, after[1..], " \t\r\n");
            }
        }
    }
    return null;
}

fn responseCompleteLen(data: []const u8) !?usize {
    const bounds = findHeaderEnd(data) orelse return null;
    const headers = data[0..bounds.header_end];
    if (getHeaderValue(headers, "Transfer-Encoding")) |te| {
        if (std.ascii.indexOfIgnoreCase(te, "chunked") != null) return error.ChunkedUnsupported;
    }
    const content_len = if (getHeaderValue(headers, "Content-Length")) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        0;
    // 修改原因：上游 keep-alive 时连接不会 EOF，必须按 Content-Length 判断响应边界。
    const total = bounds.header_end + bounds.sep_len + content_len;
    if (data.len < total) return null;
    return total;
}

fn makeErrorResponse(allocator: Allocator, status: u16, msg: []const u8) Response {
    // Triple-fallback: dupe -> alloc(0) -> zero-length compile-time literal.
    // The final literal is safe because Response.deinit guards on body.len > 0.
    const body = allocator.dupe(u8, msg) catch allocator.alloc(u8, 0) catch &.{};
    return .{ .status = status, .body = body, .allocator = allocator };
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

fn onData(stream: *RingSharedClient, ctx: ?*anyopaque, data: []u8) void {
    if (ctx) |ptr| {
        const cache: *TinyCache = @ptrCast(@alignCast(ptr));
        // 修改原因：多个 fiber 可交错等待回包，必须按 stream 查 Pipe，不能使用全局 active_pipe。
        if (cache.pipeForStream(stream)) |p| p.feed(data) catch {};
    }
}

fn onClose(stream: *RingSharedClient, ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const cache: *TinyCache = @ptrCast(@alignCast(ptr));
        cache.evictStream(stream);
    }
    if (Fiber.isYielded()) Fiber.resumeYielded("");
}

const REQUEST_POOL_SIZE = 30;

pub const HttpClient = struct {
    allocator: Allocator,
    ring_b: *RingB,
    cache: *TinyCache,
    req_pool_free: [REQUEST_POOL_SIZE]usize,
    req_pool_top: usize,
    req_pool_items: [REQUEST_POOL_SIZE]RequestContext,
    req_gen: [REQUEST_POOL_SIZE]u64,
    next_gen: u64,
    stop: bool,

    const REQUEST_TIMEOUT_MS: i64 = 5000; // 5s

    pub fn init(allocator: Allocator, ring_b: *RingB) !*HttpClient {
        const self = try allocator.create(HttpClient);
        var freelist: [REQUEST_POOL_SIZE]usize = undefined;
        for (0..REQUEST_POOL_SIZE) |i| {
            freelist[REQUEST_POOL_SIZE - 1 - i] = i;
        }
        self.* = .{
            .allocator = allocator,
            .ring_b = ring_b,
            .cache = &ring_b.http_cache,
            .req_pool_free = freelist,
            .req_pool_top = REQUEST_POOL_SIZE,
            .req_pool_items = undefined,
            .req_gen = [_]u64{0} ** REQUEST_POOL_SIZE,
            .next_gen = 0,
            .stop = false,
        };
        return self;
    }

    pub fn deinit(self: *HttpClient) void {
        @atomicStore(bool, &self.stop, true, .release);
        // 唤醒所有等待中的请求
        for (self.req_pool_items[0..], 0..) |*ctx, i| {
            if (self.isBorrowed(i)) {
                @atomicStore(bool, &ctx.done, true, .release);
            }
        }
        self.allocator.destroy(self);
    }

    fn isBorrowed(self: *HttpClient, idx: usize) bool {
        for (0..self.req_pool_top) |j| {
            if (self.req_pool_free[j] == idx) return false;
        }
        return true;
    }

    fn acquireReq(self: *HttpClient) ?*RequestContext {
        if (self.req_pool_top == 0) return null;
        self.req_pool_top -= 1;
        const idx = self.req_pool_free[self.req_pool_top];
        const ctx = &self.req_pool_items[idx];
        ctx.* = .{
            .method = "",
            .url = "",
            .headers = null,
            .body = null,
            .response = undefined,
            .done = false,
            .allocator = self.allocator,
            .client = self,
            .pool_id = idx,
            .from_pool = true,
            .gen = self.req_gen[idx],
            .cancelled = false,
        };
        return ctx;
    }

    fn releaseReq(self: *HttpClient, ctx: *RequestContext) void {
        ctx.cleanup();
        self.req_gen[ctx.pool_id] +%= 1; // bump gen → 旧 fiber notify 失效
        self.req_pool_free[self.req_pool_top] = ctx.pool_id;
        self.req_pool_top += 1;
    }

    pub fn get(self: *HttpClient, url: []const u8) !Response {
        return self.request("GET", url, null, null);
    }

    pub fn post(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("POST", url, null, body);
    }

    pub fn put(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("PUT", url, null, body);
    }

    pub fn patch(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("PATCH", url, null, body);
    }

    pub fn delete(self: *HttpClient, url: []const u8) !Response {
        return self.request("DELETE", url, null, null);
    }

    pub fn request(self: *HttpClient, method: []const u8, url: []const u8, headers: ?[]const u8, body: ?[]const u8) !Response {
        var headers_dup: ?[]u8 = if (headers) |h| self.allocator.dupe(u8, h) catch null else null;
        errdefer if (headers_dup) |h| self.allocator.free(h);
        var body_dup: ?[]u8 = if (body) |b| self.allocator.dupe(u8, b) catch {
            if (headers_dup) |h| self.allocator.free(h);
            headers_dup = null;
            return error.OutOfMemory;
        } else null;
        errdefer if (body_dup) |b| self.allocator.free(b);

        const ctx = self.acquireReq() orelse {
            if (headers_dup) |h| self.allocator.free(h);
            if (body_dup) |b| self.allocator.free(b);
            headers_dup = null;
            body_dup = null;
            return error.PoolFull;
        };
        errdefer self.releaseReq(ctx);
        ctx.method = method;
        ctx.url = url;
        ctx.headers = headers_dup;
        ctx.body = body_dup;
        ctx.done = false;
        headers_dup = null; // 所有权已移交给 ctx
        body_dup = null;

        try self.ring_b.invoke.push(self.allocator, *RequestContext, ctx, handleRequest);
        {
            // Spin-wait on the atomic done flag, set by notify() on the IO thread.
            // Single-writer (IO thread) single-reader (caller thread): atomics suffice.
            const deadline_ms = nowMs() + REQUEST_TIMEOUT_MS;
            while (!@atomicLoad(bool, &ctx.done, .acquire)) {
                std.Thread.yield() catch {};
                if (nowMs() >= deadline_ms or @atomicLoad(bool, &self.stop, .acquire)) {
                    @atomicStore(bool, &ctx.cancelled, true, .release);
                    @atomicStore(bool, &ctx.done, true, .release);
                    self.releaseReq(ctx);
                    return error.RequestTimeout;
                }
            }
        }
        const resp = ctx.response;
        self.releaseReq(ctx);
        return resp;
    }
};

const RequestContext = struct {
    method: []const u8,
    url: []const u8,
    headers: ?[]const u8,
    body: ?[]const u8,
    response: Response,
    done: bool,
    allocator: Allocator,
    client: *HttpClient,
    pool_id: usize,
    from_pool: bool,
    gen: u64,
    cancelled: bool,

    // Notify is called from the IO thread (via InvokeQueue -> handleRequest).
    // request() spins on the caller thread. Single-writer single-reader:
    // @atomicStore/.acquire is sufficient; a full mutex is unnecessary.
    fn notify(self: *RequestContext) void {
        if (@atomicLoad(bool, &self.cancelled, .acquire)) return;
        @atomicStore(bool, &self.done, true, .release);
    }

    fn cleanup(self: *RequestContext) void {
        // 修改原因：fiber 可能先释放请求体，主线程 releaseReq 还会再次 cleanup，释放后必须清空指针。
        if (self.headers) |h| {
            self.allocator.free(h);
            self.headers = null;
        }
        if (self.body) |b| {
            self.allocator.free(b);
            self.body = null;
        }
    }
};

fn handleRequest(allocator: Allocator, ctx_ptr: **RequestContext) void {
    _ = allocator;
    const ctx = ctx_ptr.*;
    const ring = ctx.client.ring_b;
    const stack = ring.allocator.alloc(u8, 65536) catch {
        ctx.response = makeErrorResponse(ctx.allocator, 502, "OOM");
        ctx.notify();
        return;
    };
    var fiber = Fiber.init(stack);
    fiber.exec(.{
        .userCtx = @ptrCast(ctx),
        .complete = struct {
            fn done(_: ?*anyopaque, _: []const u8) void {}
        }.done,
        .execFn = struct {
            fn run(user_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
                httpRequestFiber(user_ctx, complete);
                const c: *RequestContext = @ptrCast(@alignCast(user_ctx));
                c.client.ring_b.allocator.free(stack);
            }
        }.run,
    });
}

fn buildRequest(buf: []u8, method: []const u8, path: []const u8, host: []const u8, headers: ?[]const u8, body: ?[]const u8) ![]u8 {
    if (body) |b| {
        if (headers) |h| {
            return std.fmt.bufPrint(
                buf,
                "{s} {s} HTTP/1.1\r\nHost: {s}\r\n{s}Content-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
                .{ method, path, host, h, b.len, b },
            );
        }
        return std.fmt.bufPrint(
            buf,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
            .{ method, path, host, b.len, b },
        );
    }
    if (headers) |h| {
        return std.fmt.bufPrint(
            buf,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\n{s}Connection: keep-alive\r\n\r\n",
            .{ method, path, host, h },
        );
    }
    return std.fmt.bufPrint(
        buf,
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: keep-alive\r\n\r\n",
        .{ method, path, host },
    );
}

fn httpRequestFiber(user_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
    _ = complete;
    const ctx: *RequestContext = @ptrCast(@alignCast(user_ctx));
    const client = ctx.client;
    const cache = client.cache;

    const parsed = parseUrl(ctx.allocator, ctx.url) catch {
        ctx.response = makeErrorResponse(ctx.allocator, 400, "invalid URL");
        ctx.notify();
        return;
    };
    defer ctx.allocator.free(parsed.host);

    const ip = client.ring_b.dns.resolve(parsed.host) catch {
        ctx.response = makeErrorResponse(ctx.allocator, 502, "DNS resolution failed");
        ctx.notify();
        return;
    };

    const now = nowMs();
    var stream: *RingSharedClient = undefined;
    var pipe: *Pipe = undefined;

    if (cache.acquire(parsed.host, parsed.port, now)) |borrowed| {
        stream = borrowed.stream;
        pipe = borrowed.pipe;
    } else {
        stream = RingSharedClient.init(ctx.allocator, client.ring_b.rs, onData, onClose, @ptrCast(@constCast(cache)), null) catch {
            ctx.response = makeErrorResponse(ctx.allocator, 502, "client init failed");
            ctx.notify();
            return;
        };
        // Connect with 5s io_uring timeout + 1 retry (non-timeout only)
        var connect_ok = false;
        var retries: u8 = 0;
        while (retries < 2) : (retries += 1) {
            stream.connectRawTimeout(ip, parsed.port, 5000) catch {
                if (retries == 0) {
                    stream.deinit();
                    stream = RingSharedClient.init(ctx.allocator, client.ring_b.rs, onData, onClose, @ptrCast(@constCast(cache)), null) catch break;
                    continue;
                }
                break;
            };
            connect_ok = true;
            break;
        }
        if (!connect_ok) {
            stream.deinit();
            ctx.response = makeErrorResponse(ctx.allocator, 502, "connection failed");
            ctx.notify();
            return;
        }
        var new_pipe = Pipe.init(ctx.allocator, stream) catch {
            stream.deinit();
            ctx.response = makeErrorResponse(ctx.allocator, 502, "pipe init failed");
            ctx.notify();
            return;
        };
        cache.store(stream, new_pipe, parsed.host, parsed.port, now) catch |err| {
            new_pipe.deinit();
            stream.deinit();
            switch (err) {
                error.PoolFull => ctx.response = makeErrorResponse(ctx.allocator, 503, "connection pool full"),
                else => ctx.response = makeErrorResponse(ctx.allocator, 502, "OOM"),
            }
            ctx.notify();
            return;
        };
        const borrowed = cache.acquire(parsed.host, parsed.port, now) orelse {
            ctx.response = makeErrorResponse(ctx.allocator, 502, "connection cache failed");
            ctx.notify();
            return;
        };
        stream = borrowed.stream;
        pipe = borrowed.pipe;
    }

    const reader = pipe.reader();

    var req_buf: [4096]u8 = undefined;
    const req = buildRequest(&req_buf, ctx.method, parsed.path, parsed.host, ctx.headers, ctx.body) catch {
        ctx.cleanup();
        ctx.response = makeErrorResponse(ctx.allocator, 502, "request too large");
        ctx.notify();
        return;
    };
    stream.write(req) catch {
        ctx.cleanup();
        cache.evictPipe(pipe);
        // Timeout → target 关服, 不重试
        if (stream.conn_errno == -125 or stream.conn_errno == -110) {
            ctx.response = makeErrorResponse(ctx.allocator, 504, "upstream timeout");
        } else {
            ctx.response = makeErrorResponse(ctx.allocator, 502, "write failed");
        }
        ctx.notify();
        return;
    };
    ctx.cleanup();

    var resp_buf: [65536]u8 = undefined;
    var total: usize = 0;
    var complete_len: usize = 0;
    var invalid_response = false;
    const read_ok = blk: {
        while (true) {
            // 修改原因：HTTP/1.1 keep-alive 不会主动关闭连接，读到完整响应就应停止等待。
            const maybe_complete = responseCompleteLen(resp_buf[0..total]) catch {
                invalid_response = true;
                break :blk false;
            };
            if (maybe_complete) |n_complete| {
                complete_len = n_complete;
                break :blk true;
            }
            if (total >= resp_buf.len) break :blk false;
            const n = reader.read(resp_buf[total..]) catch break :blk false;
            if (n == 0) break :blk false;
            total += n;
        }
    };
    if (!read_ok) {
        cache.evictPipe(pipe);
        const msg = if (invalid_response) "invalid response" else "read failed";
        ctx.response = makeErrorResponse(ctx.allocator, 502, msg);
        ctx.notify();
        return;
    }

    if (parseResponse(ctx.allocator, resp_buf[0..complete_len])) |resp| {
        ctx.response = resp;
        ctx.notify();
        cache.release(pipe, nowMs());
    } else |_| {
        cache.evictPipe(pipe);
        ctx.response = makeErrorResponse(ctx.allocator, 502, "invalid response");
        ctx.notify();
    }
}

test "HttpClient responseCompleteLen waits for Content-Length body" {
    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello";
    try std.testing.expect(try responseCompleteLen(partial) == null);

    const full = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello worldEXTRA";
    const expected = (std.mem.indexOf(u8, full, "\r\n\r\n") orelse unreachable) + 4 + 11;
    try std.testing.expectEqual(@as(?usize, expected), try responseCompleteLen(full));

    var resp = try parseResponse(std.testing.allocator, full);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello world", resp.body);
}
