const std = @import("std");
const Allocator = std.mem.Allocator;

const HttpRing = @import("ring.zig").HttpRing;
const RingSharedClient = @import("../shared/tcp_stream.zig").RingSharedClient;
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
    _ = ctx;
    if (Fiber.isYielded()) Fiber.resumeYielded("");
}

/// 连接缓存：最近一个连接保持 1 秒，同目的地址可复用。
const CachedConn = struct {
    stream: *RingSharedClient,
    pipe: Pipe,
    host: []const u8,
    port: u16,
    last_used_ms: i64,
};

/// HTTP 客户端 — 阻塞 get() API，内部异步（独立 Ring B）。
///
/// 用法：
///   const client = try HttpClient.init(alloc);
///   defer client.deinit();
///   const resp = try client.get("http://example.com/api/data");
///   defer resp.deinit();
pub const HttpClient = struct {
    allocator: Allocator,
    ring: *HttpRing,
    thread: std.Thread,
    cache: ?CachedConn = null,
    cache_ttl_ms: i64,

    pub fn init(allocator: Allocator, io: std.Io, attach_ring_fd: ?i32, cache_ttl_ms: i64) !*HttpClient {
        const self = try allocator.create(HttpClient);
        errdefer allocator.destroy(self);

        const ring = try allocator.create(HttpRing);
        ring.* = try HttpRing.init(allocator, io, 256, attach_ring_fd);

        self.* = .{
            .allocator = allocator,
            .ring = ring,
            .thread = try std.Thread.spawn(.{}, HttpRing.runLoop, .{ring}),
            .cache_ttl_ms = cache_ttl_ms,
        };
        return self;
    }

    pub fn deinit(self: *HttpClient) void {
        self.ring.stop();
        self.thread.join();
        if (self.cache) |*c| {
            c.stream.deinit();
            c.pipe.deinit();
            self.allocator.free(c.host);
        }
        self.ring.deinit();
        self.allocator.destroy(self.ring);
        self.allocator.destroy(self);
    }

    /// 阻塞调用：GET 请求，完整 Response。
    pub fn get(self: *HttpClient, url: []const u8) !Response {
        return self.request("GET", url, null, null);
    }

    /// 阻塞调用：POST 请求，body 须为完整序列化内容（调用方负责 Content-Type / 编码）。
    pub fn post(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("POST", url, null, body);
    }

    /// 阻塞调用：PUT 请求。
    pub fn put(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("PUT", url, null, body);
    }

    /// 阻塞调用：PATCH 请求。
    pub fn patch(self: *HttpClient, url: []const u8, body: []const u8) !Response {
        return self.request("PATCH", url, null, body);
    }

    /// 阻塞调用：DELETE 请求。
    pub fn delete(self: *HttpClient, url: []const u8) !Response {
        return self.request("DELETE", url, null, null);
    }

    /// 通用 HTTP 请求（POST/PUT 自动附带 Content-Length，headers 可设 Content-Type 等）。
    pub fn request(self: *HttpClient, method: []const u8, url: []const u8, headers: ?[]const u8, body: ?[]const u8) !Response {
        // Dup body/headers here (caller's thread) so they survive the invoke queue crossing.
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
        try self.ring.invoke.push(self.allocator, *RequestContext, ctx, handleRequest);
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

    const parsed = parseUrl(ctx.allocator, ctx.url) catch {
        ctx.response = makeErrorResponse(ctx.allocator, 400, "invalid URL");
        ctx.notify();
        return;
    };
    defer ctx.allocator.free(parsed.host);

    const ip = client.ring.dns.resolve(parsed.host) catch {
        ctx.response = makeErrorResponse(ctx.allocator, 502, "DNS resolution failed");
        ctx.notify();
        return;
    };

    // ── 连接缓存：1s TTL，同 host:port 可复用 ──
    const now = nowMs();
    var stream: *RingSharedClient = undefined;
    var reuse_pipe = false;

    if (client.cache) |*c| {
        if (c.port == parsed.port and
            std.mem.eql(u8, c.host, parsed.host) and
            now - c.last_used_ms < client.cache_ttl_ms)
        {
            stream = c.stream;
            c.pipe.reset();
            active_pipe = &c.pipe;
            reuse_pipe = true;
        } else {
            c.stream.deinit();
            c.pipe.deinit();
            client.allocator.free(c.host);
            client.cache = null;
        }
    }

    if (!reuse_pipe) {
        stream = RingSharedClient.init(ctx.allocator, client.ring.rs, onData, onClose, null, null) catch {
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

        // Store in cache
        if (client.cache) |*c| {
            c.stream.deinit();
            c.pipe.deinit();
            client.allocator.free(c.host);
        }
        const host_dup = ctx.allocator.dupe(u8, parsed.host) catch {
            pipe.deinit();
            stream.deinit();
            ctx.response = makeErrorResponse(ctx.allocator, 502, "OOM");
            ctx.notify();
            return;
        };
        client.cache = .{
            .stream = stream,
            .pipe = pipe,
            .host = host_dup,
            .port = parsed.port,
            .last_used_ms = now,
        };
        active_pipe = &client.cache.?.pipe;
    }
    defer active_pipe = null;

    const reader = if (client.cache) |*c| c.pipe.reader() else unreachable;

    // Send request
    var req_buf: [4096]u8 = undefined;
    const req = buildRequest(&req_buf, ctx.method, parsed.path, parsed.host, ctx.headers, ctx.body) catch {
        ctx.cleanup();
        ctx.response = makeErrorResponse(ctx.allocator, 502, "request too large");
        ctx.notify();
        return;
    };
    stream.write(req) catch {
        ctx.cleanup();
        ctx.response = makeErrorResponse(ctx.allocator, 502, "write failed");
        ctx.notify();
        return;
    };
    ctx.cleanup();

    // Read response
    var resp_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = reader.read(resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (total >= resp_buf.len) break;
    }

    ctx.response = parseResponse(ctx.allocator, resp_buf[0..total]) catch
        makeErrorResponse(ctx.allocator, 502, "invalid response");
    ctx.notify();

    // Update cache timestamp
    if (client.cache) |*c| c.last_used_ms = nowMs();
}
