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
const SlotWorkspace = @import("stack_pool.zig").SlotWorkspace;
const HttpWork = @import("stack_pool.zig").HttpWork;
const WsWork = @import("stack_pool.zig").WsWork;
const ComputeWork = @import("stack_pool.zig").ComputeWork;

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
    // Debug: verify sentinel intact (catches buffer overflow from previous slot user)
    std.debug.assert(slot.line5.sentinel == 0x53574153);
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
    allocator: Allocator,
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
            out.append(allocator, idx) catch {};
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

/// 二级计算区原始字节（60B），用于短读拼包等通用操作
pub fn rawWorkspace(slot: *StackSlot) []u8 {
    return &slot.line5.ws.raw;
}

/// HTTP 协议解析工作区：存 header 解析中间态，避免重复扫描
pub fn httpWork(slot: *StackSlot) *HttpWork {
    return &slot.line5.ws.http;
}

/// WebSocket 帧解析工作区：掩码 + 分片状态
pub fn wsWork(slot: *StackSlot) *WsWork {
    return &slot.line5.ws.websocket;
}

/// Worker Pool 移交工作区：存大块内存指针 + 计算结果
pub fn computeWork(slot: *StackSlot) *ComputeWork {
    return &slot.line5.ws.compute;
}

/// ── Worker Pool 零拷贝移交 ────────────────────────────
/// 将大块 buffer 指针和 slot index 存入 workspace.compute，
/// Worker 处理完后通过 index 找回 slot 写入 result_code。

pub fn dispatchCompute(slot: *StackSlot, job_id: u64, buf_ptr: u64) void {
    const cw = &slot.line5.ws.compute;
    cw.job_id = job_id;
    cw.buffer_ptr = buf_ptr;
    cw.result_code = 0;
}

pub fn completeCompute(slot: *StackSlot, result_code: i32) void {
    slot.line5.ws.compute.result_code = result_code;
}

/// ── 哨兵校验 ──────────────────────────────────────────

pub fn sentinelIntact(slot: *const StackSlot) bool {
    return slot.line5.sentinel == 0x53574153;
}

/// ── 全系统连接管理（封装 pool + hashmap 双查）──────────
/// 过渡期同时维护 pool.slots[idx] 和 AutoHashMap(conn_id → Connection)。
/// 未来 pool.slots 自含 Connection 后这些函数消失。

/// CQE 分发入口：从 user_data 拿到 slot + Connection。
/// 幽灵事件防御 → null；hashmap 无条目 → null。
pub fn lookupByToken(
    pool: anytype,
    connections: anytype,
    user_data: u64,
) ?struct { slot: *StackSlot, conn: *anyopaque } {
    const slot = getSlotChecked(pool, user_data) orelse return null;
    const conn_ptr = connections.getPtr(slot.line2.conn_id) orelse return null;
    return .{ .slot = slot, .conn = conn_ptr };
}

/// 从旧 conn_id 反查（过渡期兼容旧调用路径）
pub fn lookupByConnId(
    pool: anytype,
    connections: anytype,
    conn_id: u64,
) ?struct { slot: *StackSlot, idx: u32, conn: *anyopaque } {
    const conn = connections.getPtr(conn_id) orelse return null;
    const idx = conn.pool_idx;
    if (idx == 0xFFFFFFFF) return null;
    const slot = &pool.slots[idx];
    return .{ .slot = slot, .idx = idx, .conn = conn };
}

/// 分配连接：pool.acquire + liveAdd + connections.put
pub fn connAlloc(
    pool: anytype,
    connections: anytype,
    fd: i32,
    conn_id: u64,
    conn_gen_id: *u32,
    now_ms: i64,
    conn: anytype,
) !u64 {
    const result = slotAlloc(pool, fd, conn_gen_id, now_ms);
    if (result.idx == 0xFFFFFFFF) return error.PoolFull;

    const slot = &pool.slots[result.idx];
    slot.line2.conn_id = conn_id;

    // caller sets conn.* fields, then passes here for put
    try connections.put(conn_id, conn);

    return result.token;
}

/// 释放连接：liveRemove + gen_id 清零 + pool.release + connections.remove
pub fn connFree(
    pool: anytype,
    connections: anytype,
    conn_id: u64,
) void {
    if (connections.getPtr(conn_id)) |conn| {
        if (conn.pool_idx != 0xFFFFFFFF) {
            slotFree(pool, conn.pool_idx);
        }
    }
    _ = connections.remove(conn_id);
}

/// 清理所有连接（deinit 时调用），对每个 conn 执行 slotFree
pub fn connFreeAll(
    pool: anytype,
    connections: anytype,
) void {
    var it = connections.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.pool_idx != 0xFFFFFFFF) {
            slotFree(pool, entry.value_ptr.pool_idx);
        }
    }
}

/// 用 sticker 替换 dispatchCqes 中的手写 gen_id 检查
/// 返回 (slot, conn_ptr)，无需调用方再查 hashmap。
pub fn dispatchToken(
    pool: anytype,
    connections: anytype,
    user_data: u64,
) ?struct { conn: *anyopaque, slot: *StackSlot } {
    const slot = getSlotChecked(pool, user_data) orelse return null;
    const conn = connections.getPtr(slot.line2.conn_id) orelse return null;
    return .{ .conn = conn, .slot = slot };
}
