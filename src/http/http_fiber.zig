const std = @import("std");
const Allocator = std.mem.Allocator;

const AsyncServer = @import("async_server.zig").AsyncServer;
const Context = @import("context.zig").Context;
const logErr = @import("http_helpers.zig").logErr;
const sticker = @import("../stack_pool_sticker.zig");

pub const HttpTaskCtx = struct {
    tag: u32,
    server: *AsyncServer,
    conn_id: u64,
    read_bid: u16 = 0,
    method_buf: [16]u8 = [_]u8{0} ** 16,
    method_len: u4 = 0,
    path_buf: [256]u8 = [_]u8{0} ** 256,
    path_len: u8 = 0,
    request_data: []u8,
    body_data: ?[]u8 = null,
};

pub fn httpTaskExec(caller_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
    const t: *HttpTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x48540001);
    const server = t.server;

    const method = t.method_buf[0..t.method_len];
    const path = t.path_buf[0..t.path_len];
    const req_data = t.request_data;

    var req_body: ?[]u8 = null;
    if (t.body_data) |bd| {
        req_body = server.allocator.dupe(u8, bd) catch null;
        server.large_pool.release(bd);
    }

    var ctx = Context{
        .request_data = req_data,
        .path = path,
        .app_ctx = server.app_ctx,
        .allocator = server.allocator,
        .status = 200,
        .content_type = .plain,
        .body = req_body,
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

pub fn httpTaskExecWrapperWithOwnership(t: *HttpTaskCtx, complete: *const fn (?*anyopaque, []const u8) void) void {
    httpTaskExec(t, complete);
    httpTaskCleanup(t);
}

pub fn httpTaskCleanup(t: *HttpTaskCtx) void {
    std.debug.assert(t.tag == 0x48540001);
    if (t.server.connections.getPtr(t.conn_id)) |conn| {
        if (!conn.read_buf_recycled) {
            conn.read_buf_recycled = true;
            t.server.buffer_pool.markReplenish(t.read_bid);
        }
        conn.read_len = 0;
        const has_stream = conn.pool_idx != 0xFFFFFFFF and
            sticker.getStream(&t.server.pool.slots[conn.pool_idx]) != null;
        if (conn.state == .streaming or has_stream) {
            if (has_stream) conn.state = .streaming;
            t.server.submitRead(t.conn_id, conn) catch {
                t.server.closeConn(t.conn_id, conn.fd);
            };
        }
    }
    t.server.http_ctx_pool.destroy(t);
}

pub fn httpTaskComplete(caller_ctx: ?*anyopaque, _: []const u8) void {
    const t: *HttpTaskCtx = @ptrCast(@alignCast(caller_ctx));
    std.debug.assert(t.tag == 0x48540001);
    t.server.shared_fiber_active = false;
    if (t.server.connections.getPtr(t.conn_id)) |conn| {
        if (!conn.read_buf_recycled) {
            conn.read_buf_recycled = true;
            t.server.buffer_pool.markReplenish(t.read_bid);
        }
        conn.read_len = 0;
        const has_stream = conn.pool_idx != 0xFFFFFFFF and
            sticker.getStream(&t.server.pool.slots[conn.pool_idx]) != null;
        if (conn.state == .streaming or has_stream) {
            if (has_stream) conn.state = .streaming;
            t.server.submitRead(t.conn_id, conn) catch {
                t.server.closeConn(t.conn_id, conn.fd);
            };
        }
    }
    t.server.http_ctx_pool.destroy(t);
}
