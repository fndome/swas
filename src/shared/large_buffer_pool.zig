const std = @import("std");
const Allocator = std.mem.Allocator;

/// ── 大报文缓冲池 ───────────────────────────────────────
///
/// 64KB 共享栈无法容纳的超大请求（Content-Length > 32KB）由此接管。
/// 每块 1MB，预分配 N 块。O(1) acquire/release，freelist 驱动。
///
/// 用法：
///   var lbp = try LargeBufferPool(16).init(alloc);  // 16 块 × 1MB = 16MB
///   const buf = lbp.acquire() orelse return error.OutOfLargeBuffers;
///   // io_uring READ CQE 直接写 buf.ptr
///   lbp.release(buf);
pub fn LargeBufferPool(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const BLOCK_SIZE = 1024 * 1024; // 1MB

        blocks: [capacity][]u8,
        freelist: [capacity]usize,
        freelist_top: usize,

        pub fn init(allocator: Allocator) !Self {
            var blocks: [capacity][]u8 = undefined;
            var freelist: [capacity]usize = undefined;

            for (0..capacity) |i| {
                blocks[i] = try allocator.alloc(u8, BLOCK_SIZE);
                freelist[i] = capacity - 1 - i;
            }

            return Self{
                .blocks = blocks,
                .freelist = freelist,
                .freelist_top = capacity,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            // Free only blocks still in pool (not acquired).
            // We track them by iterating the freelist.
            for (self.freelist[0..self.freelist_top]) |idx| {
                allocator.free(self.blocks[idx]);
            }
        }

        pub fn acquire(self: *Self) ?[]u8 {
            if (self.freelist_top == 0) return null;
            self.freelist_top -= 1;
            return self.blocks[self.freelist[self.freelist_top]];
        }

        pub fn release(self: *Self, buf: []u8) void {
            // Find block index by pointer comparison
            for (self.blocks, 0..) |block, i| {
                if (block.ptr == buf.ptr) {
                    self.freelist[self.freelist_top] = i;
                    self.freelist_top += 1;
                    return;
                }
            }
        }
    };
}
