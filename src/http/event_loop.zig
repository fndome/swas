const std = @import("std");
const linux = std.os.linux;

const AsyncServer = @import("async_server.zig").AsyncServer;
const Connection = @import("connection.zig").Connection;
const sticker = @import("../stack_pool_sticker.zig");
const Fiber = @import("../next/fiber.zig").Fiber;
const logErr = @import("http_helpers.zig").logErr;

const ACCEPT_USER_DATA = @import("../constants.zig").ACCEPT_USER_DATA;
const MAX_CQES_BATCH = @import("../constants.zig").MAX_CQES_BATCH;
const USER_TASK_BATCH = @import("../constants.zig").USER_TASK_BATCH;
const CLOSE_USER_DATA_FLAG = @import("../stack_pool.zig").CLOSE_USER_DATA_FLAG;
const CLIENT_USER_DATA_FLAG = @import("../shared/io_registry.zig").CLIENT_USER_DATA_FLAG;
const Item = @import("../next/queue.zig").Item;
const IO_QUANTUM: usize = 64;

pub fn milliTimestamp(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @as(i64, @intCast(@divTrunc(ts.nanoseconds, @as(i96, std.time.ns_per_ms))));
}

pub fn stop(self: *AsyncServer) void {
    self.should_stop = true;
}

pub fn drainPendingResumes(self: *AsyncServer) void {
    while (Fiber.popResume()) |entry| {
        if (entry.slot_idx != 0 and entry.gen_id != 0) {
            const slot = &self.pool.slots[entry.slot_idx];
            if (slot.line1.gen_id != entry.gen_id) continue;
        }
        Fiber.resumeYielded(entry.data);
    }
}

pub fn run(self: *AsyncServer) !void {
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

        if (self.accept_stalled) {
            self.submitAccept() catch |err| {
                logErr("accept chain recovery failed: {s}", .{@errorName(err)});
            };
        }

        _ = self.ring.submit() catch |err| {
            logErr("submit failed: {s}", .{@errorName(err)});
        };

        const n = try self.ring.copy_cqes(&cqes, 0);
        if (n > 0) {
            dispatchCqes(self, &cqes, n);
            drainPendingResumes(self);
            drainNextTasks(self);
            drainTick(self);
            if (self.fiber_shared) |fs| fs.tick();
            ttlScanTick(self);
            continue;
        }

        if (self.timeout_user_data == 0) {
            submitIdleTimeout(self) catch |err| {
                logErr("submitIdleTimeout failed: {s}", .{@errorName(err)});
            };
        }

        {
            const n_user = self.submit_registry.drain(&user_tasks_buf);
            for (user_tasks_buf[0..n_user]) |*req| {
                executeNext(req);
            }
        }

        drainNextTasks(self);
        drainTick(self);
        if (self.fiber_shared) |fs| fs.tick();
        ttlScanTick(self);

        _ = try self.ring.submit_and_wait(1);
        const n2 = try self.ring.copy_cqes(&cqes, 0);
        dispatchCqes(self, &cqes, n2);
        drainPendingResumes(self);
        if (self.fiber_shared) |fs| fs.tick();
        ttlScanTick(self);
    }
}

pub fn dispatchCqes(self: *AsyncServer, cqes: []linux.io_uring_cqe, n: usize) void {
    for (cqes[0..n], 0..) |cqe, i| {
        const user_data = cqe.user_data;
        const res = cqe.res;

        if (self.timeout_user_data != 0 and user_data == self.timeout_user_data) {
            self.timeout_user_data = 0;
            self.ring.cqe_seen(&cqes[i]);
            continue;
        }

        if (user_data == ACCEPT_USER_DATA) {
            self.ring.cqe_seen(&cqes[i]);
            self.onAcceptComplete(res, user_data);
        } else if ((user_data & CLOSE_USER_DATA_FLAG) != 0) {
            const raw_ud = user_data & ~CLOSE_USER_DATA_FLAG;
            const close_conn_id: u64 = if (sticker.getSlotChecked(&self.pool, raw_ud)) |slot|
                slot.line2.conn_id
            else
                raw_ud;
            self.closeConn(close_conn_id, 0);
            self.ring.cqe_seen(&cqes[i]);
        } else if ((user_data & CLIENT_USER_DATA_FLAG) != 0) {
            defer self.ring.cqe_seen(&cqes[i]);
            self.io_registry.dispatch(user_data, res);
        } else {
            const disp = sticker.dispatchToken(&self.pool, &self.connections, user_data);
            const conn_ptr = if (disp) |d| @as(*Connection, @ptrCast(@alignCast(d.conn))) else {
                if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                    self.buffer_pool.markReplenish(sticker.extractBid(cqe.flags));
                }
                self.ring.cqe_seen(&cqes[i]);
                continue;
            };
            const conn_id = conn_ptr.id;
            defer self.ring.cqe_seen(&cqes[i]);

            if (conn_ptr.state == .reading or conn_ptr.state == .processing) {
                self.onReadComplete(conn_id, res, user_data, cqe.flags);
            } else if (conn_ptr.state == .receiving_body) {
                self.onBodyChunk(conn_id, res);
            } else if (conn_ptr.state == .streaming) {
                self.onStreamRead(conn_id, res, user_data, cqe.flags);
            } else if (conn_ptr.state == .writing) {
                self.onWriteComplete(conn_id, res, user_data);
            } else if (conn_ptr.state == .ws_reading) {
                self.onWsFrame(conn_id, res, user_data, cqe.flags);
            } else if (conn_ptr.state == .ws_writing) {
                self.onWsWriteComplete(conn_id, res, user_data);
            } else if (conn_ptr.state == .closing) {
                if (!conn_ptr.read_buf_recycled and cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                    conn_ptr.read_buf_recycled = true;
                    const bid = @as(u16, @truncate(cqe.flags >> 16));
                    self.buffer_pool.markReplenish(bid);
                }
                self.closeConn(conn_id, conn_ptr.fd);
            } else {
                self.closeConn(conn_id, conn_ptr.fd);
            }
        }
    }
}

pub fn drainNextTasks(self: *AsyncServer) void {
    if (self.next) |*n| {
        var count: usize = 0;
        while (count < IO_QUANTUM) : (count += 1) {
            const item = n.ringbuffer.pop() orelse break;
            executeNext(&item);
        }
    }
}

pub fn executeNext(req: *const Item) void {
    req.execute(req.ctx, req.on_complete);
}

pub fn submitIdleTimeout(self: *AsyncServer) !void {
    const user_data = self.nextUserData();
    _ = self.ring.timeout(user_data, &self.timeout_ts, 0, 0) catch {
        self.timeout_user_data = 0;
        return;
    };
    self.timeout_user_data = user_data;
}

pub fn ttlScanTick(self: *AsyncServer) void {
    const now = milliTimestamp(self.io);
    self.ttl_scan_out.clearRetainingCapacity();
    sticker.ttlScan(
        &self.pool,
        self.allocator,
        now,
        @intCast(self.cfg.idle_timeout_ms),
        &self.ttl_scan_cursor,
        512,
        &self.ttl_scan_out,
    );
    for (self.ttl_scan_out.items) |idx| {
        const slot = &self.pool.slots[idx];
        self.closeConn(slot.line2.conn_id, slot.line1.fd);
    }
}

pub fn checkIdleConnections(self: *AsyncServer) void {
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
        if (self.getConn(conn_id)) |conn| {
            self.closeConn(conn_id, conn.fd);
        }
    }
}

pub fn drainTick(self: *AsyncServer) void {
    self.dns_resolver.tick();
    self.rs.invoke.drain(self.allocator);
    for (self.tick_hooks.items) |hook| {
        hook(self);
    }
}
