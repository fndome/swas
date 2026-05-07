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
///
/// 状态机 (per-block) 防御 io_uring 内核重试导致的幽灵双重释放:
///   0 = IDLE (free)
///   1 = BUSY (acquired, in-flight)
/// release() 使用 CAS 从 BUSY → IDLE，若已为 IDLE 则跳过（幂等释放）。
pub fn BufferBlockPool(comptime block_size: usize, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const STATE_IDLE: u8 = 0;
        const STATE_BUSY: u8 = 1;

        blocks: [capacity][]u8,
        freelist: [capacity]usize,
        freelist_top: usize,
        states: [capacity]u8,

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
                .states = [_]u8{STATE_IDLE} ** capacity,
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
            const idx = self.freelist[self.freelist_top];
            // Atomic store-release: publish BUSY before returning pointer
            @atomicStore(u8, &self.states[idx], STATE_BUSY, .release);
            return self.blocks[idx];
        }

        /// 幂等释放：CAS BUSY → IDLE。若已为 IDLE（双重释放/幽灵 CQE），
        /// 记录错误并跳过，保护 freelist 元数据不被破坏。
        pub fn release(self: *Self, buf: []u8) void {
            for (self.blocks, 0..) |block, i| {
                if (block.ptr == buf.ptr) {
                    const prev = @cmpxchgStrong(u8, &self.states[i], STATE_BUSY, STATE_IDLE, .acquire, .monotonic);
                    if (prev == null) {
                        // CAS succeeded: BUSY → IDLE
                        self.freelist[self.freelist_top] = i;
                        self.freelist_top += 1;
                        return;
                    } else if (prev.? == STATE_IDLE) {
                        // Double-free detected: io_uring retry or close/error collision.
                        // The buffer was already released — do NOT re-add to freelist.
                        std.log.err("LargeBufferPool: double-free detected for block idx={d} ptr=0x{x}", .{ i, @intFromPtr(buf.ptr) });
                        return;
                    }
                    // prev is still BUSY (CAS spuriously failed). Retry once.
                    _ = @cmpxchgStrong(u8, &self.states[i], STATE_BUSY, STATE_IDLE, .acquire, .monotonic);
                    self.freelist[self.freelist_top] = i;
                    self.freelist_top += 1;
                    return;
                }
            }
            // Buffer not owned by this pool — caller bug
            std.log.err("LargeBufferPool.release: buffer 0x{x} not found in pool", .{@intFromPtr(buf.ptr)});
        }
    };
}

/// 向后兼容: 1MB × N 块, 用于大报文 (Content-Length > 32KB)
pub fn LargeBufferPool(comptime capacity: usize) type {
    return BufferBlockPool(1024 * 1024, capacity);
}
