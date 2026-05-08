const std = @import("std");
const linux = std.os.linux;

const AsyncServer = @import("../http/async_server.zig").AsyncServer;
const Connection = @import("../http/connection.zig").Connection;
const sticker = @import("../stack_pool_sticker.zig");
const logErr = @import("../http/http_helpers.zig").logErr;
const milliTimestamp = @import("../http/event_loop.zig").milliTimestamp;

const MAX_FIXED_FILES = @import("../constants.zig").MAX_FIXED_FILES;
const ACCEPT_USER_DATA = @import("../constants.zig").ACCEPT_USER_DATA;

pub fn nextConnId(self: *AsyncServer) u64 {
    const id = self.next_conn_id;
    self.next_conn_id +%= 1;
    return id;
}

pub fn allocFixedIndex(self: *AsyncServer) !u16 {
    if (self.fixed_file_freelist.pop()) |idx| return idx;
    if (self.fixed_file_next < MAX_FIXED_FILES) {
        const idx = self.fixed_file_next;
        self.fixed_file_next += 1;
        return idx;
    }
    return error.OutOfFixedFileSlots;
}

pub fn freeFixedIndex(self: *AsyncServer, idx: u16) void {
    self.fixed_file_freelist.append(self.allocator, idx) catch |err| {
        logErr("freeFixedIndex: append failed for idx {d}: {s}", .{ idx, @errorName(err) });
    };
}

pub fn onAcceptComplete(self: *AsyncServer, res: i32, user_data: u64) void {
    _ = user_data;
    if (res < 0) {
        logErr("accept failed: {}", .{res});
        self.accept_stalled = true;
        self.submitAccept() catch |err| {
            logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        };
        return;
    }
    const conn_fd: i32 = @intCast(res);
    const conn_id = nextConnId(self);

    const alloc = sticker.slotAlloc(&self.pool, conn_fd, &self.conn_gen_id, milliTimestamp(self.io));
    if (alloc.idx == 0xFFFFFFFF) {
        const rc = linux.close(conn_fd);
        if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
        self.accept_stalled = true;
        self.submitAccept() catch |err| logErr("failed to resubmit accept (pool full): {s}", .{@errorName(err)});
        return;
    }
    const pool_idx = alloc.idx;
    self.pool.slots[pool_idx].line2.conn_id = conn_id;

    var conn = Connection{
        .id = conn_id,
        .fd = conn_fd,
        .last_active_ms = milliTimestamp(self.io),
        .pool_idx = pool_idx,
        .gen_id = self.pool.slots[pool_idx].line1.gen_id,
        .active_list_pos = self.pool.slots[pool_idx].line2.active_list_pos,
    };

    if (self.use_fixed_files) {
        const idx = allocFixedIndex(self) catch {
            const rc = linux.close(conn_fd);
            if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
            sticker.slotFree(&self.pool, pool_idx);
            self.accept_stalled = true;
            self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        };
        if (self.ring.register_files_update(idx, &[_]linux.fd_t{conn_fd})) {
            conn.fixed_index = idx;
        } else |_| {
            freeFixedIndex(self, idx);
            const rc = linux.close(conn_fd);
            if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
            sticker.slotFree(&self.pool, pool_idx);
            self.accept_stalled = true;
            self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
            return;
        }
    }

    self.connections.put(conn_id, conn) catch {
        sticker.slotFree(&self.pool, pool_idx);
        if (self.use_fixed_files) {
            const idx = conn.fixed_index;
            _ = self.ring.register_files_update(idx, &[_]linux.fd_t{-1}) catch {};
            freeFixedIndex(self, idx);
        }
        const rc = linux.close(conn_fd);
        if (rc != 0) logErr("close conn_fd={d} failed: {d}", .{ conn_fd, rc });
        self.accept_stalled = true;
        self.submitAccept() catch |err| logErr("failed to resubmit accept after put error: {s}", .{@errorName(err)});
        return;
    };
    const conn_ptr = self.getConn(conn_id) orelse {
        const rc = linux.close(conn_fd);
        if (rc != 0) logErr("close orphan conn_fd={d} failed: {d}", .{ conn_fd, rc });
        self.accept_stalled = true;
        self.submitAccept() catch |err| logErr("failed to resubmit accept: {s}", .{@errorName(err)});
        return;
    };
    self.submitRead(conn_id, conn_ptr) catch |err| {
        if (err == error.RingFull) {} else {
            logErr("submitRead failed for fd {}: {s}", .{ conn_fd, @errorName(err) });
            self.closeConn(conn_id, conn_fd);
        }
        self.accept_stalled = true;
        self.submitAccept() catch |err2| logErr("failed to resubmit accept after read error: {s}", .{@errorName(err2)});
        return;
    };
    self.submitAccept() catch |err| {
        self.accept_stalled = true;
        logErr("failed to resubmit accept: {s}", .{@errorName(err)});
    };
}
