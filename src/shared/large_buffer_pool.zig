const std = @import("std");
const Allocator = std.mem.Allocator;

/// ── 通用块缓冲池 ────────────────────────────────────────
///
/// 预分配 N 块, 每块 block_size 字节。O(1) acquire/release, freelist 驱动。
/// 用于 IM 的大 JSON、文件 I/O、数据库结果集等 — 任何需要确定性内存的场景。
///
/// 用法:
///   var pool = try BufferBlockPool(65536, 32).init(alloc); // 32 × 64KB
///   const buf = pool.acquire() orelse return error.OutOfBlocks;
///   defer pool.release(buf);
///   // io_uring read/write CQE 直接写 buf.ptr
///
/// release() 是 O(n) 指针扫描, 适合 块数 <= 64 的场景。
/// 需要更大池子用 std.heap.MemoryPool 或 arena allocator。
pub fn BufferBlockPool(comptime block_size: usize, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        blocks: [capacity][]u8,
        freelist: [capacity]usize,
        freelist_top: usize,

        pub fn init(allocator: Allocator) !Self {
            var blocks: [capacity][]u8 = undefined;
            var freelist: [capacity]usize = undefined;
            for (0..capacity) |i| {
                blocks[i] = try allocator.alloc(u8, block_size);
                freelist[i] = capacity - 1 - i;
            }
            return Self{
                .blocks = blocks,
                .freelist = freelist,
                .freelist_top = capacity,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
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

/// 向后兼容: 1MB × N 块, 用于大报文 (Content-Length > 32KB)
pub fn LargeBufferPool(comptime capacity: usize) type {
    return BufferBlockPool(1024 * 1024, capacity);
}
