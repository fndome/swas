const std = @import("std");
const Allocator = std.mem.Allocator;

const InvokeNode = struct {
    next: ?*InvokeNode,
    exec: *const fn (allocator: Allocator, ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const InvokeQueue = struct {
    head: ?*InvokeNode align(@alignOf(usize)) = null,

    /// 任意线程安全投递。execFn 在 drain 时执行，负责释放 ctx 内部资源。
    pub fn push(
        self: *InvokeQueue,
        allocator: Allocator,
        comptime T: type,
        ctx: T,
        comptime execFn: fn (allocator: Allocator, ctx_ptr: *T) void,
    ) !void {
        const user = try allocator.create(T);
        errdefer allocator.destroy(user);
        user.* = ctx;

        const node = try allocator.create(InvokeNode);
        node.* = .{
            .next = null,
            .exec = struct {
                fn call(a: Allocator, ptr: *anyopaque) void {
                    const u: *T = @ptrCast(@alignCast(ptr));
                    execFn(a, u);
                    a.destroy(u);
                }
            }.call,
            .ctx = @ptrCast(user),
        };

        var head = @atomicLoad(?*InvokeNode, &self.head, .monotonic);
        while (true) {
            node.next = head;
            head = @cmpxchgWeak(?*InvokeNode, &self.head, head, node, .release, .monotonic) orelse break;
        }
    }

    /// 仅 IO 线程调用。交换链表并逐条执行。
    pub fn drain(self: *InvokeQueue, allocator: Allocator) void {
        const head = @atomicRmw(?*InvokeNode, &self.head, .Xchg, null, .acquire);
        var node = head;
        while (node) |n| {
            defer allocator.destroy(n);
            const next = n.next;
            n.exec(allocator, n.ctx);
            node = next;
        }
    }
};
