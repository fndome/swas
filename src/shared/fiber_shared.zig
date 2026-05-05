const std = @import("std");
const Allocator = std.mem.Allocator;

/// ── 调度胶水 ─────────────────────────────────────────────
///
/// 纯调度层。持有所有出站 ring 的调度句柄，IO 线程每轮调用 tick() 遍历收割。
///
/// 扩展新 ring（如 RingC for NATS, RingD for MySQL）只需实现 RingTrait：
///
///   const nats_ring = RingC.init(...);
///   try nats_ring.registerWith(&fiber_shared);
pub const FiberShared = struct {
    ports: std.ArrayList(RingTrait),

    pub fn init(allocator: Allocator) !FiberShared {
        return FiberShared{ .ports = std.ArrayList(RingTrait).init(allocator) };
    }

    pub fn deinit(self: *FiberShared) void {
        self.ports.deinit();
    }

    /// 注册出站 ring。任何实现了 RingTrait 的类型都可以注册。
    pub fn register(self: *FiberShared, port: RingTrait) !void {
        try self.ports.append(port);
    }

    /// IO 线程每轮事件循环调用。非阻塞遍历所有已注册 ring。
    pub fn tick(self: *FiberShared) void {
        for (self.ports.items) |port| {
            port.tickFn(port.ptr);
        }
    }
};

/// RingTrait —— 调度层看到的 ring 契约。
///
/// 每个出站 ring 在注册时提供：
///   ptr    —— 指向具体 ring 实例的指针（*RingB / *RingC / ...）
///   tickFn —— tick 回调，FiberShared.tick() 每轮调用一次
///
/// tickFn 的契约（必须实现）：
///   1. dns.tick()      —— 驱动 DNS 查询状态机
///   2. invoke.drain()  —— 处理跨线程任务投递
///   3. ring.submit()   —— 提交待处理的 SQE
///   4. ring.copy_cqes()—— 非阻塞收割 CQE
///   5. registry.dispatch(ud, res) —— 分发 CQE 到注册的回调
///
/// 参考实现见 RingB.tick()。
pub const RingTrait = struct {
    ptr: *anyopaque,
    tickFn: *const fn (*anyopaque) void,
};
