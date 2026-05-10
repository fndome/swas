const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const AsyncServer = @import("async_server.zig").AsyncServer;
const Connection = @import("connection.zig").Connection;
const WsWriteQueueNode = @import("connection.zig").WsWriteQueueNode;
const WsHandler = @import("../ws/server.zig").WsHandler;
const Opcode = @import("../ws/types.zig").Opcode;
const ws_frame = @import("../ws/frame.zig");
const ws_upgrade = @import("../ws/upgrade.zig");
const helpers = @import("http_helpers.zig");
const sticker = @import("../stack_pool_sticker.zig");
const Fiber = @import("../next/fiber.zig").Fiber;
const ws_fiber = @import("ws_fiber.zig");
const logErr = helpers.logErr;
const milliTimestamp = @import("event_loop.zig").milliTimestamp;

pub fn tryWsUpgrade(self: *AsyncServer, conn_id: u64, conn: *Connection, path: []const u8, data: []const u8, bid: u16) void {
    var pending_token: ?[]u8 = null;
    defer if (pending_token) |token| self.allocator.free(token);

    const full_uri = helpers.getFullUri(data);
    if (full_uri) |uri| {
        if (helpers.extractQueryParam(uri, "token")) |token| {
            pending_token = self.allocator.dupe(u8, token) catch null;
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
    // 修改原因：只有握手成功后才能把 token 挂到连接上，避免失败升级路径泄漏或污染 HTTP 连接状态。
    conn.ws_token = pending_token;
    pending_token = null;
    conn.keep_alive = false;
    conn.write_headers_len = len;
    conn.write_offset = 0;
    conn.state = .writing;
    if (conn.pool_idx != 0xFFFFFFFF) sticker.switchToWs(&self.pool.slots[conn.pool_idx]);
    self.submitWrite(conn_id, conn) catch {
        self.closeConn(conn_id, conn.fd);
    };
}

pub fn onWsFrame(self: *AsyncServer, conn_id: u64, res: i32, user_data: u64, cqe_flags: u32) void {
    _ = user_data;
    if (res <= 0) {
        const conn = self.getConn(conn_id) orelse return;
        self.closeConn(conn_id, conn.fd);
        return;
    }
    const conn = self.getConn(conn_id) orelse return;

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

    // Refresh TTL activity timestamp for WebSocket connections.
    // slot.line2.last_active_ms is only set at accept time; without this,
    // WebSocket connections time out after idle_timeout_ms despite being active.
    if (conn.pool_idx != 0xFFFFFFFF) {
        const now_ws = milliTimestamp(self.io);
        self.pool.slots[conn.pool_idx].line2.last_active_ms = now_ws;
    }

    const frame = ws_frame.parseFrame(read_buf[0..nread]) catch {
        self.buffer_pool.markReplenish(bid);
        conn.read_len = 0;
        self.closeConn(conn_id, conn.fd);
        return;
    };

    if (conn.pool_idx != 0xFFFFFFFF) {
        const ww = sticker.wsWork(&self.pool.slots[conn.pool_idx]);
        ww.payload_len = frame.payload.len;
        ww.is_final = frame.fin;
    }

    switch (frame.opcode) {
        .close => {
            const total = ws_frame.frameSize(frame.payload.len);
            if (!self.ensureWriteBuf(conn, total)) {
                self.buffer_pool.markReplenish(bid);
                conn.read_len = 0;
                self.closeConn(conn_id, conn.fd);
                return;
            }
            const wbuf = conn.response_buf.?;
            _ = ws_frame.writeFrame(wbuf, .{
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
            conn.write_headers_len = total;
            conn.write_offset = 0;
            conn.state = .ws_writing;
            conn.keep_alive = false;
            self.submitWrite(conn_id, conn) catch {
                self.closeConn(conn_id, conn.fd);
            };
        },
        .ping => {
            const pong_total = ws_frame.frameSize(frame.payload.len);
            if (!self.ensureWriteBuf(conn, pong_total)) {
                self.buffer_pool.markReplenish(bid);
                conn.read_len = 0;
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
                return;
            }
            const wbuf = conn.response_buf.?;
            _ = ws_frame.writeFrame(wbuf, .{
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
            conn.write_headers_len = pong_total;
            conn.write_offset = 0;
            conn.state = .ws_writing;
            self.submitWrite(conn_id, conn) catch {
                self.closeConn(conn_id, conn.fd);
            };
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
                payload_tier = 0xFF;
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

            if (self.shared_fiber_active) {
                if (self.next) |*n| {
                    if (n.push(ws_fiber.WsTaskCtx, t.*, ws_fiber.wsTaskExecWrapperWithOwnership, self.cfg.fiber_stack_size_kb * 1024)) {
                        self.ws_ctx_pool.destroy(t);
                    } else {
                        // 修改原因：WS 任务入队失败时必须释放复制前持有的 payload，避免池泄漏。
                        ws_fiber.wsTaskCleanup(t);
                        self.closeConn(conn_id, conn.fd);
                        return;
                    }
                } else {
                    self.buffer_pool.freeTieredWriteBuf(payload_full, payload_tier);
                    self.ws_ctx_pool.destroy(t);
                    handler(conn_id, &frame, self.ws_server.ctx);
                }
            } else {
                var fiber = Fiber.init(self.shared_fiber_stack);
                self.shared_fiber_active = true;
                fiber.exec(.{
                    .userCtx = t,
                    .complete = ws_fiber.wsTaskComplete,
                    .execFn = ws_fiber.wsTaskExec,
                });
                // If the handler yielded (e.g. DB / DNS wait), do NOT
                // re-arm the read here. The complete callback fires
                // after resume and handles read submission, preserving
                // frame ordering.
                if (Fiber.isYielded()) return;
            }

            if (conn.state != .ws_writing) {
                conn.state = .ws_reading;
                self.submitRead(conn_id, conn) catch {
                    self.closeConn(conn_id, conn.fd);
                };
            }
        },
    }
}

pub fn onWsWriteComplete(self: *AsyncServer, conn_id: u64, res: i32, user_data: u64) void {
    _ = user_data;
    if (res <= 0) {
        const conn = self.getConn(conn_id) orelse return;
        // CQE means kernel is done — clear flag for closeConn & retry
        if (conn.pool_idx != 0xFFFFFFFF) {
            self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
        }
        self.closeConn(conn_id, conn.fd);
        return;
    }
    const conn = self.getConn(conn_id) orelse return;
    conn.write_offset += @as(usize, @intCast(res));
    if (conn.write_offset >= conn.write_headers_len) {
        conn.write_retries = 0;
        // write completed — clear flag before flushWsWriteQueue may call
        // submitWrite again (which checks writev_in_flight)
        if (conn.pool_idx != 0xFFFFFFFF) {
            self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
        }
        if (conn.response_buf) |buf| {
            self.buffer_pool.freeTieredWriteBuf(buf, conn.response_buf_tier);
            conn.response_buf = null;
        }
        conn.write_offset = 0;
        conn.write_headers_len = 0;
        if (!conn.keep_alive) {
            self.closeConn(conn_id, conn.fd);
            return;
        }
        flushWsWriteQueue(self, conn_id, conn);
    } else {
        conn.write_retries += 1;
        if (conn.write_retries > maxWriteRetries(conn.write_headers_len)) {
            logErr("ws write retries exceeded for fd {} ({} attempts)", .{ conn.fd, conn.write_retries });
            if (conn.pool_idx != 0xFFFFFFFF) {
                self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
            }
            self.closeConn(conn_id, conn.fd);
            return;
        }
        // clear flag so submitWrite retry can set it again
        if (conn.pool_idx != 0xFFFFFFFF) {
            self.pool.slots[conn.pool_idx].line4.writev_in_flight = 0;
        }
        self.submitWrite(conn_id, conn) catch {
            self.closeConn(conn_id, conn.fd);
        };
    }
}

pub fn wsSendFn(ctx: *anyopaque, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
    const self: *AsyncServer = @ptrCast(@alignCast(ctx));
    try sendWsFrame(self, conn_id, opcode, payload);
}

pub fn sendWsFrame(self: *AsyncServer, conn_id: u64, opcode: Opcode, payload: []const u8) !void {
    const conn = self.getConn(conn_id) orelse return;

    if (conn.is_writing) {
        const dup = self.allocator.dupe(u8, payload) catch {
            return error.OutOfMemory;
        };
        const node = self.allocator.create(WsWriteQueueNode) catch {
            self.allocator.free(dup);
            return error.OutOfMemory;
        };
        node.* = .{ .opcode = opcode, .payload = dup, .next = null };
        if (conn.ws_write_queue_tail) |tail| {
            tail.next = node;
        } else {
            conn.ws_write_queue_head = node;
        }
        conn.ws_write_queue_tail = node;
        return;
    }

    conn.is_writing = true;
    submitWsWrite(self, conn_id, conn, opcode, payload) catch |err| {
        conn.is_writing = false;
        return err;
    };
}

fn submitWsWrite(self: *AsyncServer, conn_id: u64, conn: *Connection, opcode: Opcode, payload: []const u8) !void {
    const total = ws_frame.frameSize(payload.len);
    if (!self.ensureWriteBuf(conn, total)) {
        return error.OutOfMemory;
    }
    const wbuf = conn.response_buf.?;
    if (total > wbuf.len) {
        return error.BufferTooSmall;
    }
    _ = ws_frame.writeFrame(wbuf, .{
        .opcode = opcode,
        .fin = true,
        .payload = payload,
    }) catch {
        return error.FrameWriteFailed;
    };
    conn.write_headers_len = total;
    conn.write_offset = 0;
    conn.state = .ws_writing;
    try self.submitWrite(conn_id, conn);
}

pub fn flushWsWriteQueue(self: *AsyncServer, conn_id: u64, conn: *Connection) void {
    if (conn.ws_write_queue_head) |node| {
        conn.ws_write_queue_head = node.next;
        if (conn.ws_write_queue_head == null) {
            conn.ws_write_queue_tail = null;
        }
        const opcode = node.opcode;
        const payload = node.payload;
        self.allocator.destroy(node);

        submitWsWrite(self, conn_id, conn, opcode, payload) catch |err| {
            logErr("flushWsWriteQueue: submitWsWrite failed for fd {}: {s}", .{ conn.fd, @errorName(err) });
            self.allocator.free(payload);
            conn.is_writing = false;
            self.closeConn(conn_id, conn.fd);
            return;
        };
        self.allocator.free(payload);
    } else {
        conn.is_writing = false;
        conn.state = .ws_reading;
        self.submitRead(conn_id, conn) catch |err| {
            logErr("flushWsWriteQueue: submitRead failed for fd {}: {s}", .{ conn.fd, @errorName(err) });
            self.closeConn(conn_id, conn.fd);
        };
    }
}

pub fn drainWsWriteQueue(self: *AsyncServer, conn: *Connection) void {
    var node = conn.ws_write_queue_head;
    while (node) |n| {
        const next = n.next;
        self.allocator.free(n.payload);
        self.allocator.destroy(n);
        node = next;
    }
    conn.ws_write_queue_head = null;
    conn.ws_write_queue_tail = null;
    conn.is_writing = false;
}

fn maxWriteRetries(total: usize) u8 {
    if (total <= 1460) return 3;
    const base: usize = total / 4096;
    const retries: usize = if (base < 4) @as(usize, 4) else if (base > 64) @as(usize, 64) else base;
    return @intCast(retries);
}
