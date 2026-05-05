const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const StackPool = @import("stack_pool.zig").StackPool;
const StackSlot = @import("stack_pool.zig").StackSlot;
const packUserData = @import("stack_pool.zig").packUserData;
const unpackGenId = @import("stack_pool.zig").unpackGenId;
const unpackIdx = @import("stack_pool.zig").unpackIdx;
const CLOSE_USER_DATA_FLAG = @import("stack_pool.zig").CLOSE_USER_DATA_FLAG;
const OVERSIZED_THRESHOLD = @import("stack_pool.zig").OVERSIZED_THRESHOLD;

pub fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}

/// ── 全系统总开关 ──────────────────────────────────────
///
/// 从 io_uring CQE user_data 中解出 index + gen_id，校验后返回 Slot 指针。
/// 幽灵事件防御：gen_id 不匹配 → null，调用方必须丢弃该 CQE。
///
/// 用法：
///   const slot = getSlotChecked(&pool, cqe.user_data) orelse {
///       if (cqe.flags & IORING_CQE_F_BUFFER != 0)
///           pool.buffer_pool.markReplenish(extractBid(cqe.flags));
///       continue;
///   };
pub fn getSlotChecked(pool: anytype, user_data: u64) ?*StackSlot {
    const idx = unpackIdx(user_data);
    const gen = unpackGenId(user_data);
    if (gen == 0) return null;
    if (idx >= pool.slots.len) return null;

    const slot = &pool.slots[idx];
    if (slot.line1.gen_id != gen) return null;
    return slot;
}

pub fn extractBid(cqe_flags: u32) u16 {
    return @truncate(cqe_flags >> 16);
}

/// ── Slot 生命周期 ─────────────────────────────────────

/// 分配并初始化一个槽位。返回 index + user_data token。
pub fn slotAlloc(pool: anytype, fd: i32, conn_gen_id: *u32, now_ms: i64) struct { idx: u32, token: u64 } {
    const idx = pool.acquire() orelse return .{ .idx = 0xFFFFFFFF, .token = 0 };
    const gen_id = conn_gen_id.*;
    conn_gen_id.* +%= 1;

    const slot = &pool.slots[idx];
    slot.line1.gen_id = gen_id;
    slot.line1.fd = fd;
    slot.line1.state = .reading;
    slot.line1.oversized = false;
    slot.line1.buf_recycled = false;
    slot.line1.write_offset = 0;
    slot.line1.write_headers_len = 0;
    slot.line1.write_retries = 0;
    slot.line1.keep_alive = false;
    slot.line1.req_count = 0;
    slot.line1.req_window_ms = 0;
    slot.line2.last_active_ms = now_ms;
    slot.line2.birth_ms = now_ms;
    slot.line2.is_writing = false;
    slot.line2.active_list_pos = pool.liveAdd(idx);

    return .{ .idx = idx, .token = packUserData(gen_id, idx) };
}

/// 释放槽位：注销 live 列表、清零 gen_id、归还 freelist。
pub fn slotFree(pool: anytype, idx: u32) void {
    const slot = &pool.slots[idx];
    const list_pos = slot.line2.active_list_pos;
    if (pool.liveRemove(list_pos)) |swapped_idx| {
        pool.slots[swapped_idx].line2.active_list_pos = list_pos;
    }
    slot.line1.gen_id = 0;
    pool.release(idx);
}

/// ── TTL 扫描器 ────────────────────────────────────────

/// 增量滑窗 TTL 扫描。每轮检查 scan_cursor 起的 window 个活跃槽位。
/// 返回超时槽位的索引列表（调用方负责 close）。
pub fn ttlScan(
    pool: anytype,
    now_ms: i64,
    timeout_ms: i64,
    scan_cursor: *u32,
    window: u32,
    out: *std.ArrayList(u32),
) void {
    const live = pool.live.items;
    if (live.len == 0) return;

    const start = scan_cursor.* % @as(u32, @intCast(live.len));
    const end = @min(start + window, @as(u32, @intCast(live.len)));

    for (live[start..end]) |idx| {
        const slot = &pool.slots[idx];
        if (now_ms - slot.line2.last_active_ms >= timeout_ms) {
            out.append(idx) catch {};
        }
    }

    scan_cursor.* = end;
    if (scan_cursor.* >= live.len) {
        scan_cursor.* = 0;
    }
}

/// ── 大报文判定 ────────────────────────────────────────

pub fn isOversized(content_length: u64) bool {
    return content_length > OVERSIZED_THRESHOLD;
}

/// ── 限速检查 ──────────────────────────────────────────

/// 简单滑动窗口限速。返回 true 表示放行，false 表示超限。
pub fn rateLimitCheck(slot: *StackSlot, now_ms: i64, max_per_window: u32, window_ms: i64) bool {
    if (now_ms - slot.line1.req_window_ms >= window_ms) {
        slot.line1.req_window_ms = now_ms;
        slot.line1.req_count = 1;
        return true;
    }
    if (slot.line1.req_count >= max_per_window) return false;
    slot.line1.req_count += 1;
    return true;
}

/// ── user_data 构造快捷方式 ────────────────────────────

pub fn readToken(slot: *const StackSlot) u64 {
    return packUserData(slot.line1.gen_id, @truncate(0)); // idx set by caller
}

pub fn closeToken(slot: *const StackSlot, idx: u32) u64 {
    return packUserData(slot.line1.gen_id, idx) | CLOSE_USER_DATA_FLAG;
}

/// ── Workspace 访问 ────────────────────────────────────

/// 获取工作区的最大连续块（Line5 workspace: 60B）
pub fn workspace(slot: *StackSlot) []u8 {
    return &slot.line5.workspace;
}

/// Worker Pool 预解析暂存区（Line3: 24B）
pub fn workerScratch(slot: *StackSlot) []u8 {
    return &slot.line3.worker_scratch;
}

/// 写路径临时暂存区（Line4: 48B）
pub fn writeScratch(slot: *StackSlot) []u8 {
    return &slot.line4.write_scratch;
}

/// ── 哨兵校验 ──────────────────────────────────────────

pub fn sentinelIntact(slot: *const StackSlot) bool {
    return slot.line5.sentinel == 0x53574153;
}
