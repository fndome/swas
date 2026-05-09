const std = @import("std");
const Allocator = std.mem.Allocator;
pub const CLIENT_USER_DATA_FLAG: u64 = 1 << 62;

pub const CqeDispatchFn = *const fn (*anyopaque, u64, i32) void;

const RegisteredEntry = struct {
    ptr: *anyopaque,
    dispatch: CqeDispatchFn,
    gen_id: u32,
};

/// io_uring 句柄统一注册表。支持 Ring A（server 内置）和出站 Ring B/C/D。
///
/// user_data 编码（与 StackPool 对齐，共同防止幽灵 CQE）：
///   CLIENT_USER_DATA_FLAG | ((gen_id & 0x0FFF_FFFF) << 32) | (counter & 0xFFFF_FFFF)
///
/// gen_id 单调递增，remove 后失效，防止 u32 counter 回绕导致新旧连接碰撞。
pub const IORegistry = struct {
    streams: std.AutoHashMap(u32, RegisteredEntry),
    counter: u32 = 0,
    gen_counter: u32 = 1,

    pub fn init(allocator: Allocator) IORegistry {
        return .{ .streams = std.AutoHashMap(u32, RegisteredEntry).init(allocator) };
    }

    pub fn deinit(self: *IORegistry) void {
        self.streams.deinit();
    }

    /// 分配 user_data token，编码 gen_id + counter。
    pub fn allocUserData(self: *IORegistry) u64 {
        const gen = self.gen_counter;
        self.gen_counter +%= 1;
        const idx = self.counter;
        self.counter +%= 1;

        return CLIENT_USER_DATA_FLAG | (@as(u64, gen & 0x0FFF_FFFF) << 32) | idx;
    }

    pub fn register(self: *IORegistry, ud: u64, ptr: *anyopaque, on_cqe: CqeDispatchFn) !void {
        const gen = @as(u32, @truncate((ud >> 32) & 0x0FFF_FFFF));
        const idx = @as(u32, @truncate(ud));
        try self.streams.put(idx, .{ .ptr = ptr, .dispatch = on_cqe, .gen_id = gen });
    }

    pub fn remove(self: *IORegistry, ud: u64) void {
        const idx = @as(u32, @truncate(ud));
        _ = self.streams.remove(idx);
    }

    /// 分发 CQE：解码 counter 查表 + gen_id 校验，防止幽灵事件。
    pub fn dispatch(self: *IORegistry, ud: u64, res: i32) void {
        const gen = @as(u32, @truncate((ud >> 32) & 0x0FFF_FFFF));
        const idx = @as(u32, @truncate(ud));
        if (self.streams.getPtr(idx)) |entry| {
            if (entry.gen_id != gen) return;
            entry.dispatch(entry.ptr, ud, res);
        }
    }
};
