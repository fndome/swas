const std = @import("std");
const Allocator = std.mem.Allocator;

/// 为了榨干 1C 核心的 L1/L2 Cache，建议你的 HttpStack 采用以下布局：
/// 字节偏移            字段内容                        理由
/// 0 - 31      fd, gen_id, state, write_offset         IO 热区：CQE 回调最先访问，需在同一 Cache Line
/// 32 - 63     retry_count, buffer_id, is_closed       状态位：控制重试和清理逻辑
/// 64 - 127    user_id, last_active_ms                 业务区：仅在逻辑解析时访问
///
/// 单线程固定大小对象池。O(1) acquire/release，无锁，缓存友好。
///
/// acquire: freelist[--top] → 返回索引
/// release: freelist[top++] = idx → 归还
///
/// user_data = (gen_id << 32) | idx，解决 FD/索引复用的幽灵事件。
///
/// 用法：
///   const MAX = 1_048_576;
///   var pool = try StackPool(Slot, MAX).init(allocator);
///   const idx = pool.acquire();           → u32 索引
///   pool.slots[idx] = .{ ... };
///   const ud = pool.userData(idx);        → 打包 gen_id|idx
///   pool.release(idx);
pub fn StackPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        slots: []T,
        freelist: []u32,
        freelist_top: u32,

        pub fn init(allocator: Allocator) !Self {
            const slots = try allocator.alloc(T, capacity);
            const freelist = try allocator.alloc(u32, capacity);

            // Initialize freelist: all indices free, top at 0 (pop on acquire)
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

        /// 获取一个空闲槽位，返回索引。满则 null。
        pub fn acquire(self: *Self) ?u32 {
            if (self.freelist_top == 0) return null;
            self.freelist_top -= 1;
            return self.freelist[self.freelist_top];
        }

        /// 归还槽位。
        pub fn release(self: *Self, idx: u32) void {
            self.freelist[self.freelist_top] = idx;
            self.freelist_top += 1;
        }
    };
}

/// StackPool 槽位的最小头部 —— 所有业务 slot 嵌入此结构。
/// 字段布局对齐缓存行，gen_id 占高 32 位打包进 user_data。
pub const SlotHeader = packed struct {
    gen_id: u32,
    buf_recycled: bool = false,
    _pad: u7 = 0,
};

/// 打包 user_data：高 32 位 gen_id，低 32 位索引。
pub inline fn packUserData(gen_id: u32, idx: u32) u64 {
    return (@as(u64, gen_id) << 32) | idx;
}

/// 解包 user_data → gen_id
pub inline fn unpackGenId(ud: u64) u32 {
    return @intCast(ud >> 32);
}

/// 解包 user_data → idx
pub inline fn unpackIdx(ud: u64) u32 {
    return @intCast(ud & 0xFFFFFFFF);
}
