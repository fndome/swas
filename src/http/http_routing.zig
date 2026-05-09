const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const AsyncServer = @import("async_server.zig").AsyncServer;
const Connection = @import("connection.zig").Connection;
const Context = @import("context.zig").Context;
const Middleware = @import("types.zig").Middleware;
const Handler = @import("types.zig").Handler;
const WsHandler = @import("../ws/server.zig").WsHandler;
const MiddlewareStore = @import("middleware_store.zig").MiddlewareStore;
const WildcardEntry = @import("middleware_store.zig").WildcardEntry;
const PathRule = @import("../antpath.zig").PathRule;
const helpers = @import("http_helpers.zig");
const getMethodFromRequest = helpers.getMethodFromRequest;
const getPathFromRequest = helpers.getPathFromRequest;
const logErr = helpers.logErr;
const ws_upgrade = @import("../ws/upgrade.zig");
const http_fiber = @import("http_fiber.zig");
const http_response = @import("http_response.zig");
const Fiber = @import("../next/fiber.zig").Fiber;
const Next = @import("../next/next.zig").Next;
const HttpTaskCtx = http_fiber.HttpTaskCtx;
const httpTaskExec = http_fiber.httpTaskExec;
const httpTaskExecWrapperWithOwnership = http_fiber.httpTaskExecWrapperWithOwnership;
const httpTaskComplete = http_fiber.httpTaskComplete;
const statusText = http_response.statusText;

/// 注册中间件，在 fiber 中执行。可用 Next.submit() 卸 CPU 重活。
pub fn use(self: *AsyncServer, pattern: []const u8, middleware: Middleware) !void {
    ensureNext(self);

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
pub fn useThenRespondImmediately(self: *AsyncServer, pattern: []const u8, middleware: Middleware) !void {
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

pub fn ensureNext(self: *AsyncServer) void {
    if (self.next != null) return;
    const kb = if (self.cfg.fiber_stack_size_kb == 0) @as(u16, 64) else self.cfg.fiber_stack_size_kb;
    self.next = Next.init(self.allocator, @as(u32, @intCast(kb)) * 1024);
    self.next.?.setDefault();
}

pub fn register(self: *AsyncServer, method: []const u8, path: []const u8, handler: Handler) !void {
    ensureNext(self);
    const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ method, path });
    const old = try self.handlers.fetchPut(key, handler);
    if (old) |kv| {
        self.allocator.free(kv.key);
    }
}

pub fn GET(self: *AsyncServer, path: []const u8, handler: Handler) !void {
    try register(self, "GET", path, handler);
}

pub fn POST(self: *AsyncServer, path: []const u8, handler: Handler) !void {
    try register(self, "POST", path, handler);
}

pub fn PUT(self: *AsyncServer, path: []const u8, handler: Handler) !void {
    try register(self, "PUT", path, handler);
}

pub fn PATCH(self: *AsyncServer, path: []const u8, handler: Handler) !void {
    try register(self, "PATCH", path, handler);
}

pub fn DELETE(self: *AsyncServer, path: []const u8, handler: Handler) !void {
    try register(self, "DELETE", path, handler);
}

pub fn ws(self: *AsyncServer, path: []const u8, handler: WsHandler) !void {
    try self.ws_server.register(path, handler);
}

pub fn processBodyRequest(self: *AsyncServer, conn_id: u64, conn: *Connection, body_buf: []u8) void {
    const bid = conn.read_bid;
    const header_buf = self.buffer_pool.getReadBuf(bid);
    const effective_buf = header_buf;
    const path = getPathFromRequest(effective_buf) orelse {
        self.buffer_pool.markReplenish(bid);
        self.large_pool.release(body_buf);
        conn.read_len = 0;
        self.respond(conn, 400, "Bad Request");
        return;
    };

    if (self.respond_middlewares.has_global or
        self.respond_middlewares.precise.count() > 0 or
        self.respond_middlewares.wildcard.items.len > 0)
    {
        var temp_ctx = Context{
            .request_data = effective_buf,
            .request_body = body_buf,
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
        var matched_respond_middleware = false;

        if (self.respond_middlewares.has_global) {
            matched_respond_middleware = true;
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
                matched_respond_middleware = true;
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
                    matched_respond_middleware = true;
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

        // 修改原因：当前 path 未命中快速中间件时要继续走普通 handler，不能提前返回空 200。
        if (matched_respond_middleware) {
            self.large_pool.release(body_buf);
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
    }

    const has_async = self.middlewares.has_global or
        self.middlewares.precise.count() > 0 or
        self.middlewares.wildcard.items.len > 0 or
        self.handlers.count() > 0;
    if (has_async) {
        const method_str = getMethodFromRequest(effective_buf) orelse "POST";
        const t = self.http_ctx_pool.create(self.allocator) catch {
            self.buffer_pool.markReplenish(bid);
            self.large_pool.release(body_buf);
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
            .request_data = @constCast(effective_buf),
            .body_data = @constCast(body_buf),
        };
        @memcpy(t.method_buf[0..method_cap], method_str[0..method_cap]);
        @memcpy(t.path_buf[0..path_cap], path[0..path_cap]);

        if (self.shared_fiber_active) {
            if (self.next) |*n| {
                if (n.push(HttpTaskCtx, t.*, httpTaskExecWrapperWithOwnership, self.cfg.fiber_stack_size_kb * 1024)) {
                    self.http_ctx_pool.destroy(t);
                } else {
                    // 修改原因：入队失败时必须释放 body_buf/read buffer，避免大块池泄漏。
                    http_fiber.httpTaskCleanup(t);
                    self.respond(conn, 503, "Service Unavailable");
                }
            } else {
                http_fiber.httpTaskCleanup(t);
                self.respond(conn, 503, "Service Unavailable");
            }
        } else {
            var fiber = Fiber.init(self.shared_fiber_stack);
            self.shared_fiber_active = true;
            fiber.exec(.{
                .userCtx = t,
                .complete = httpTaskComplete,
                .execFn = httpTaskExec,
            });
        }
        conn.read_len = 0;
        return;
    }

    self.large_pool.release(body_buf);
    self.buffer_pool.markReplenish(bid);
    conn.read_len = 0;
    self.respond(conn, 404, "Not Found");
}
