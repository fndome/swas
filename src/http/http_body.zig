const std = @import("std");
const linux = std.os.linux;

const AsyncServer = @import("async_server.zig").AsyncServer;
const Connection = @import("connection.zig").Connection;
const StackSlot = @import("../stack_pool.zig").StackSlot;
const packUserData = @import("../stack_pool.zig").packUserData;
const sticker = @import("../stack_pool_sticker.zig");
const StreamHandle = @import("../next/chunk_stream.zig").StreamHandle;
const logErr = @import("http_helpers.zig").logErr;

pub fn submitBodyRead(self: *AsyncServer, conn: *Connection, large_buf: []u8, slot: *StackSlot) !void {
    const remaining = slot.line3.large_buf_len - slot.line3.large_buf_offset;
    if (remaining == 0) return;
    const user_data = packUserData(conn.gen_id, conn.pool_idx);
    const fd = if (conn.fixed_index != 0xFFFF) @as(i32, @intCast(conn.fixed_index)) else conn.fd;
    const dest = large_buf[slot.line3.large_buf_offset..][0..@min(remaining, large_buf.len - slot.line3.large_buf_offset)];
    const sqe = try self.ring.read(user_data, fd, .{ .buffer = dest }, 0);
    if (conn.fixed_index != 0xFFFF) sqe.flags |= linux.IOSQE_FIXED_FILE;
}

pub fn onBodyChunk(self: *AsyncServer, conn_id: u64, res: i32) void {
    const conn = self.getConn(conn_id) orelse return;
    const slot = if (conn.pool_idx != 0xFFFFFFFF) &self.pool.slots[conn.pool_idx] else {
        if (res <= 0) self.closeConn(conn_id, conn.fd);
        return;
    };

    if (sticker.getStream(slot)) |stream_ptr| {
        const stream: *StreamHandle = @ptrCast(@alignCast(stream_ptr));
        if (res <= 0) {
            _ = stream.finish();
            sticker.clearStream(slot);
            if (slot.line3.large_buf_ptr != 0) {
                const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
                self.large_pool.release(buf);
                slot.line3.large_buf_ptr = 0;
            }
            self.closeConn(conn_id, conn.fd);
            return;
        }
        const n: u32 = @intCast(res);
        const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
        const data = buf[slot.line3.large_buf_offset..][0..@as(usize, @intCast(n))];
        _ = stream.feed(data);
        slot.line3.large_buf_offset += n;
        submitBodyRead(self, conn, buf, slot) catch {
            self.large_pool.release(buf);
            slot.line3.large_buf_ptr = 0;
            sticker.clearStream(slot);
            self.closeConn(conn_id, conn.fd);
        };
        return;
    }

    if (res <= 0) {
        if (conn.pool_idx != 0xFFFFFFFF) {
            if (slot.line3.large_buf_ptr != 0) {
                const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
                self.large_pool.release(buf);
                slot.line3.large_buf_ptr = 0;
            }
        }
        self.closeConn(conn_id, conn.fd);
        return;
    }
    slot.line3.large_buf_offset += @intCast(res);
    if (slot.line3.large_buf_offset >= slot.line3.large_buf_len) {
        conn.state = .processing;
        const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
        self.processBodyRequest(conn_id, conn, buf);
    } else {
        const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
        submitBodyRead(self, conn, buf, slot) catch {
            self.large_pool.release(buf);
            slot.line3.large_buf_ptr = 0;
            self.closeConn(conn_id, conn.fd);
        };
    }
}

pub fn onStreamRead(self: *AsyncServer, conn_id: u64, res: i32, user_data: u64, cqe_flags: u32) void {
    _ = user_data;
    const conn = self.getConn(conn_id) orelse return;
    const slot = if (conn.pool_idx != 0xFFFFFFFF) &self.pool.slots[conn.pool_idx] else {
        self.closeConn(conn_id, conn.fd);
        return;
    };
    const stream_ptr = sticker.getStream(slot) orelse {
        self.closeConn(conn_id, conn.fd);
        return;
    };
    const stream: *StreamHandle = @ptrCast(@alignCast(stream_ptr));

    if (res <= 0) {
        _ = stream.finish();
        sticker.clearStream(slot);
        self.closeConn(conn_id, conn.fd);
        return;
    }

    if (cqe_flags & linux.IORING_CQE_F_BUFFER != 0) {
        const bid = @as(u16, @truncate(cqe_flags >> 16));
        const read_buf = self.buffer_pool.getReadBuf(bid);
        const n = @as(usize, @intCast(res));
        _ = stream.feed(read_buf[0..n]);
        self.buffer_pool.markReplenish(bid);
    } else {
        const n = @as(u32, @intCast(res));
        const buf: []u8 = @as([*]u8, @ptrFromInt(slot.line3.large_buf_ptr))[0..slot.line3.large_buf_len];
        const data = buf[slot.line3.large_buf_offset..][0..@as(usize, @intCast(n))];
        _ = stream.feed(data);
        slot.line3.large_buf_offset += n;
    }

    self.submitRead(conn_id, conn) catch {
        self.closeConn(conn_id, conn.fd);
    };
}
