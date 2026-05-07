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
        self.allocator.free(self.body);
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) {
        return error.TlsNotSupported;
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }
    const path_start = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = if (path_start) |p| rest[0..p] else rest;
    const path = if (path_start) |p| rest[p..] else "/";
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |c| host_port[0..c] else host_port;
    const port: u16 = if (colon) |c| std.fmt.parseInt(u16, host_port[c + 1 ..], 10) catch 80 else 80;
    return .{ .host = try allocator.dupe(u8, host), .port = port, .path = path };
}

fn parseResponse(allocator: Allocator, data: []const u8) !Response {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
        std.mem.indexOf(u8, data, "\n\n") orelse
        return error.InvalidResponse;
    const sep_len: usize = if (data[header_end] == '\r') @as(usize, 4) else @as(usize, 2);
    const first_line_end = std.mem.indexOfScalar(u8, data, '\r') orelse
        std.mem.indexOfScalar(u8, data, '\n') orelse
        return error.InvalidResponse;
    var status: u16 = 0;
    var parts = std.mem.splitScalar(u8, data[0..first_line_end], ' ');
    _ = parts.next();
    if (parts.next()) |code| status = std.fmt.parseInt(u16, code, 10) catch 500;
    const body = try allocator.dupe(u8, data[header_end + sep_len ..]);
    return .{ .status = status, .body = body, .allocator = allocator };
}

fn makeErrorResponse(allocator: Allocator, status: u16, msg: []const u8) Response {
    const body = allocator.dupe(u8, msg) catch allocator.alloc(u8, 0) catch &.{};
    return .{ .status = status, .body = body, .allocator = allocator };
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

threadlocal var active_pipe: ?*Pipe = null;

fn onData(ctx: ?*anyopaque, data: []u8) void {
    _ = ctx;
    if (active_pipe) |p| p.feed(data) catch {};
}

fn onClose(ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const cache: *TinyCache = @ptrCast(@alignCast(ptr));
        cache.evict();
    }
    if (Fiber.isYielded()) Fiber.resumeYielded("");
}

pub const HttpClient = struct {
    allocator: Allocator,
    ring_b: *RingB,
    /// 指向 ring_b.http_cache（内建缓存，由 RingB.tick() 自动淘汰过期条目）
    cache: *TinyCache,

    pub fn init(allocator: Allocator, ring_b: *RingB) !*HttpClient {
        const self = try allocator.create(HttpClient);
        self.* = .{
            .allocator = allocator,
            .ring_b = ring_b,
            .cache = &ring_b.http_cache,
        };
        return self;
    }

    pub fn deinit(self: *HttpClient) void {
        self.allocator.destroy(self);
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
        const headers_dup: ?[]u8 = if (headers) |h| self.allocator.dupe(u8, h) catch null else null;
        errdefer if (headers_dup) |h| self.allocator.free(h);
        const body_dup: ?[]u8 = if (body) |b| self.allocator.dupe(u8, b) catch {
            if (headers_dup) |h| self.allocator.free(h);
            return error.OutOfMemory;
        } else null;
        errdefer if (body_dup) |b| self.allocator.free(b);

        const ctx = try self.allocator.create(RequestContext);
        errdefer self.allocator.destroy(ctx);

        ctx.* = .{
            .method = method,
            .url = url,
            .headers = headers_dup,
            .body = body_dup,
            .response = undefined,
            .done = false,
            .mutex = .{},
            .cond = .{},
            .allocator = self.allocator,
            .client = self,
        };
        try self.ring_b.invoke.push(self.allocator, *RequestContext, ctx, handleRequest);
        ctx.mutex.lock();
        while (!ctx.done) ctx.cond.wait(&ctx.mutex);
        ctx.mutex.unlock();
        const resp = ctx.response;
        self.allocator.destroy(ctx);
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
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    allocator: Allocator,
    client: *HttpClient,

    fn notify(self: *RequestContext) void {
        self.mutex.lock();
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
    }

    fn cleanup(self: *RequestContext) void {
        if (self.headers) |h| self.allocator.free(h);
        if (self.body) |b| self.allocator.free(b);
    }
};

fn handleRequest(allocator: Allocator, ctx_ptr: *RequestContext) void {
    _ = allocator;
    const ctx = ctx_ptr;
    const client = ctx.client;
    const stack = client.allocator.alloc(u8, 65536) catch {
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
                c.client.allocator.free(stack);
            }
        }.run,
    });
}

fn buildRequest(
    buf: []u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    headers: ?[]const u8,
    body: ?[]const u8,
) ![]const u8 {
    if (body) |b| {
        const content_len = b.len;
        if (headers) |h| {
            return std.fmt.bufPrint(buf,
                "{s} {s} HTTP/1.1\r\nHost: {s}\r\n{s}Content-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
                .{ method, path, host, h, content_len, b },
            );
        }
        return std.fmt.bufPrint(buf,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
            .{ method, path, host, content_len, b },
        );
    } else {
        if (headers) |h| {
            return std.fmt.bufPrint(buf,
                "{s} {s} HTTP/1.1\r\nHost: {s}\r\n{s}Connection: keep-alive\r\n\r\n",
                .{ method, path, host, h },
            );
        }
        return std.fmt.bufPrint(buf,
            "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: keep-alive\r\n\r\n",
            .{ method, path, host },
        );
    }
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

    if (cache.acquire(parsed.host, parsed.port, now)) |borrowed| {
        active_pipe = borrowed.pipe;
        stream = borrowed.stream;
    } else {
        stream = RingSharedClient.init(ctx.allocator, client.ring_b.rs, onData, onClose, @ptrCast(@constCast(cache)), null) catch {
            ctx.response = makeErrorResponse(ctx.allocator, 502, "client init failed");
            ctx.notify();
            return;
        };
        stream.connectRaw(ip, parsed.port) catch {
            stream.deinit();
            ctx.response = makeErrorResponse(ctx.allocator, 502, "connection failed");
            ctx.notify();
            return;
        };

        var pipe = Pipe.init(ctx.allocator, stream) catch {
            stream.deinit();
            ctx.response = makeErrorResponse(ctx.allocator, 502, "pipe init failed");
            ctx.notify();
            return;
        };

        cache.store(stream, pipe, parsed.host, parsed.port, now) catch |err| {
            pipe.deinit();
            stream.deinit();
            switch (err) {
                error.PoolFull => ctx.response = makeErrorResponse(ctx.allocator, 503, "connection pool full"),
                else => ctx.response = makeErrorResponse(ctx.allocator, 502, "OOM"),
            }
            ctx.notify();
            return;
        };
        active_pipe = cache.pipe orelse unreachable;
    }
    defer active_pipe = null;

    const reader = cache.pipe.?.reader();

    var req_buf: [4096]u8 = undefined;
    const req = buildRequest(&req_buf, ctx.method, parsed.path, parsed.host, ctx.headers, ctx.body) catch {
        ctx.cleanup();
        ctx.response = makeErrorResponse(ctx.allocator, 502, "request too large");
        ctx.notify();
        return;
    };
    stream.write(req) catch {
        ctx.cleanup();
        cache.evictPipe(active_pipe.?);
        ctx.response = makeErrorResponse(ctx.allocator, 502, "write failed");
        ctx.notify();
        return;
    };
    ctx.cleanup();

    var resp_buf: [65536]u8 = undefined;
    var total: usize = 0;
    const read_ok = blk: {
        while (true) {
            const n = reader.read(resp_buf[total..]) catch break :blk false;
            if (n == 0) break;
            total += n;
            if (total >= resp_buf.len) break;
        }
        break :blk true;
    };
    if (!read_ok) {
        cache.evictPipe(active_pipe.?);
        ctx.response = makeErrorResponse(ctx.allocator, 502, "read failed");
        ctx.notify();
        return;
    }

    if (parseResponse(ctx.allocator, resp_buf[0..total])) |resp| {
        ctx.response = resp;
        ctx.notify();
        cache.release(active_pipe.?, nowMs());
    } else |_| {
        cache.evictPipe(active_pipe.?);
        ctx.response = makeErrorResponse(ctx.allocator, 502, "invalid response");
        ctx.notify();
    }
}
