const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const BUFFER_SIZE = @import("constants.zig").BUFFER_SIZE;
const READ_BUF_COUNT = @import("constants.zig").READ_BUF_COUNT;
const READ_BUF_GROUP_ID = @import("constants.zig").READ_BUF_GROUP_ID;

pub const BufferPool = struct {
    allocator: Allocator,
    slab: []u8,
    capacity: usize,
    read_count: usize,

    write_free: std.ArrayList(u16),

    replenish_queue: std.ArrayList(u16),

    pub fn init(allocator: Allocator, count: usize, read_count: usize) !BufferPool {
        const slab = try allocator.alloc(u8, count * BUFFER_SIZE);
        var wf = std.ArrayList(u16).empty;
        for (read_count..count) |i| {
            wf.append(allocator, @intCast(i)) catch {};
        }
        return BufferPool{
            .allocator = allocator,
            .slab = slab,
            .capacity = count,
            .read_count = read_count,
            .write_free = wf,
            .replenish_queue = std.ArrayList(u16).empty,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        self.write_free.deinit(self.allocator);
        self.replenish_queue.deinit(self.allocator);
        self.allocator.free(self.slab);
    }

    pub fn provideAllReads(self: *BufferPool, ring: *linux.IoUring) !void {
        _ = try ring.provide_buffers(
            0,
            self.slab.ptr,
            BUFFER_SIZE,
            self.read_count,
            READ_BUF_GROUP_ID,
            0,
        );
    }

    pub fn getReadBuf(self: *BufferPool, bid: u16) []u8 {
        const i = @as(usize, bid);
        return self.slab[i * BUFFER_SIZE .. (i + 1) * BUFFER_SIZE];
    }

    pub fn markReplenish(self: *BufferPool, bid: u16) void {
        self.replenish_queue.append(self.allocator, bid) catch {};
    }

    pub fn flushReplenish(self: *BufferPool, ring: *linux.IoUring) !void {
        for (self.replenish_queue.items) |bid| {
            const ptr = self.slab.ptr + @as(usize, bid) * BUFFER_SIZE;
            _ = try ring.provide_buffers(
                0,
                ptr,
                BUFFER_SIZE,
                1,
                READ_BUF_GROUP_ID,
                bid,
            );
        }
        self.replenish_queue.clearRetainingCapacity();
    }

    pub fn allocWriteBuf(self: *BufferPool) ?[]u8 {
        if (self.write_free.items.len == 0) return null;
        const bid = self.write_free.pop().?;
        const i = @as(usize, bid);
        return self.slab[i * BUFFER_SIZE .. (i + 1) * BUFFER_SIZE];
    }

    pub fn freeWriteBuf(self: *BufferPool, buf: []u8) void {
        const idx = (@intFromPtr(buf.ptr) - @intFromPtr(self.slab.ptr)) / BUFFER_SIZE;
        self.write_free.append(self.allocator, @intCast(idx)) catch {};
    }
};
