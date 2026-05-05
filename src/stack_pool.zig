const std = @import("std");
const Allocator = std.mem.Allocator;

const ConnState = @import("http/connection.zig").ConnState;

/// StackPool: O(1) 连续数组连接池，替代 AutoHashMap。
/// user_data = (gen_id << 32) | idx，防 FD 复用幽灵事件。
pub fn StackPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        slots: []T,
        freelist: []u32,
        freelist_top: u32,

        pub fn init(allocator: Allocator) !Self {
            const slots = try allocator.alloc(T, capacity);
            const freelist = try allocator.alloc(u32, capacity);

            for (freelist, 0..) |*f, i| {
                f.* = @intCast(capacity - 1 - i);
            }

            return Self{
                .slots = slots,
                .freelist = freelist,
                .freelist_top = @intCast(capacity),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.slots);
            allocator.free(self.freelist);
        }

        pub fn acquire(self: *Self) ?u32 {
            if (self.freelist_top == 0) return null;
            self.freelist_top -= 1;
            return self.freelist[self.freelist_top];
        }

        pub fn release(self: *Self, idx: u32) void {
            self.freelist[self.freelist_top] = idx;
            self.freelist_top += 1;
        }
    };
}

pub inline fn packUserData(gen_id: u32, idx: u32) u64 {
    return (@as(u64, gen_id) << 32) | idx;
}

pub inline fn unpackGenId(ud: u64) u32 {
    return @intCast(ud >> 32);
}

pub inline fn unpackIdx(ud: u64) u32 {
    return @intCast(ud & 0xFFFFFFFF);
}

/// ── 缓存行子结构 ───────────────────────────────────────

const CacheLine1 = extern struct {
    gen_id: u32 = 0,
    state: ConnState = .reading,
    oversized: bool = false,
    buf_recycled: bool = false,
    fd: i32 = 0,
    write_offset: u32 = 0,
    write_headers_len: u32 = 0,
    read_bid: u16 = 0,
    write_retries: u8 = 0,
    keep_alive: bool = false,
    _fill: [37]u8 = [_]u8{0} ** 37,
};

comptime {
    if (@sizeOf(CacheLine1) != 64) {
        @compileError("CacheLine1 must be 64 bytes, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(CacheLine1)}));
    }
}

const CacheLine2 = extern struct {
    user_id: u64 = 0,
    last_active_ms: i64 = 0,
    prev_live: u32 = 0,
    next_live: u32 = 0,
    write_start_ms: i64 = 0,
    is_writing: bool = false,
    _fill: [31]u8 = [_]u8{0} ** 31,
};

comptime {
    if (@sizeOf(CacheLine2) != 64) {
        @compileError("CacheLine2 must be 64 bytes, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(CacheLine2)}));
    }
}

const CacheLine3 = extern struct {
    pending_buffer_ptr: u64 = 0,
    fiber_context: u64 = 0,
    waiting_since_ms: i64 = 0,
    large_buf_ptr: u64 = 0,
    large_buf_len: u32 = 0,
    large_buf_offset: u32 = 0,
    _fill: [24]u8 = [_]u8{0} ** 24,
};

comptime {
    if (@sizeOf(CacheLine3) != 64) {
        @compileError("CacheLine3 must be 64 bytes, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(CacheLine3)}));
    }
}

const CacheLine4_6 = extern struct {
    response_buf_ptr: u64 = 0,
    response_buf_tier: u8 = 0,
    _pad: [3]u8 = [_]u8{0} ** 3,
    response_buf_len: u32 = 0,
    write_iovs: [2]std.posix.iovec_const = [_]std.posix.iovec_const{
        .{ .base = undefined, .len = 0 },
        .{ .base = undefined, .len = 0 },
    },
    ws_write_queue_head: u64 = 0,
    ws_write_queue_tail: u64 = 0,
    ws_token_ptr: u64 = 0,
    ws_token_len: u32 = 0,
    _fill: [48]u8 = [_]u8{0} ** 48,
};

comptime {
    if (@sizeOf(CacheLine4_6) != 128) {
        @compileError("CacheLine4_6 must be 128 bytes, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(CacheLine4_6)}));
    }
}

/// ── 连接槽位 (320 bytes, <400 budget) ──────────────────
///
/// 四组子结构各占独立缓存行，IO 循环最热路径只碰 line1。
///   line1 ( 64B): fd, gen_id, state, write_offset — CQE dispatch
///   line2 ( 64B): user_id, last_active_ms, prev/next_live — TTL scan
///   line3 ( 64B): 异步锚点 + 大报文 — Worker Pool / LargeBufferPool
///   line4 (128B): response_buf, write_iovs, WS queue — 写路径低频
pub const StackSlot = extern struct {
    line1: CacheLine1 align(64),
    line2: CacheLine2,
    line3: CacheLine3,
    line4: CacheLine4_6,

    comptime {
        if (@sizeOf(StackSlot) > 400) {
            @compileError("StackSlot exceeds 400 bytes: " ++ std.fmt.comptimePrint("{}", .{@sizeOf(StackSlot)}));
        }
        // Verify line2 starts at offset 64
        if (@offsetOf(StackSlot, "line2") != 64) {
            @compileError("line2 offset must be 64, got " ++ std.fmt.comptimePrint("{}", .{@offsetOf(StackSlot, "line2")}));
        }
        if (@offsetOf(StackSlot, "line3") != 128) {
            @compileError("line3 offset must be 128, got " ++ std.fmt.comptimePrint("{}", .{@offsetOf(StackSlot, "line3")}));
        }
        if (@offsetOf(StackSlot, "line4") != 192) {
            @compileError("line4 offset must be 192, got " ++ std.fmt.comptimePrint("{}", .{@offsetOf(StackSlot, "line4")}));
        }
    }
};

pub const OVERSIZED_THRESHOLD: usize = 32 * 1024;
pub const COMPUTATION_TIMEOUT_MS: i64 = 2000;
