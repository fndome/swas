const std = @import("std");
const IoFiber = std.Io.fiber;

pub const FiberCall = struct {
    userCtx: ?*anyopaque,
    complete: *const fn (?*anyopaque, []const u8) void,
    execFn: *const fn (?*anyopaque, *const fn (?*anyopaque, []const u8) void) void,
};

threadlocal var active_call: ?FiberCall = null;
threadlocal var caller_context: ?*IoFiber.Context = null;

/// 当前正在执行的 fiber context，供 Pipe 等组件 yield 使用
threadlocal var current_context: ?*IoFiber.Context = null;

/// ── yield/resume 状态 ──
threadlocal var yielded_fiber: ?*IoFiber.Context = null;
threadlocal var yielded_result: ?[]const u8 = null;
pub threadlocal var saved_call: ?FiberCall = null;
threadlocal var yield_seq: u64 = 0;

/// ── worker 线程 parking 状态（transient，fiber.exec 返回后由 workerLoop 读取） ──
pub threadlocal var parked_ctx: ?*IoFiber.Context = null;
pub threadlocal var parked_call: ?FiberCall = null;
pub threadlocal var parked_poll: ?*const fn (*anyopaque) bool = null;
pub threadlocal var parked_poll_ctx: ?*anyopaque = null;

fn trampoline() void {
    const c = active_call.?;
    c.execFn(c.userCtx, c.complete);
    var fiber_ctx: IoFiber.Context = undefined;
    _ = IoFiber.contextSwitch(&.{ .old = &fiber_ctx, .new = caller_context.? });
    unreachable;
}

pub const Fiber = struct {
    context: IoFiber.Context,

    pub fn init(stack: []u8) Fiber {
        const sp = @intFromPtr(stack.ptr + stack.len);
        const aligned_sp = sp & ~@as(u64, 15);
        return .{
            .context = .{
                .rsp = aligned_sp,
                .rbp = 0,
                .rip = @intFromPtr(&trampoline),
            },
        };
    }

    pub fn exec(self: *Fiber, c: FiberCall) void {
        active_call = c;
        current_context = &self.context;
        var caller = Fiber{ .context = undefined };
        caller_context = &caller.context;
        _ = IoFiber.contextSwitch(&.{ .old = &caller.context, .new = &self.context });
        current_context = null;
        active_call = null;
        caller_context = null;
    }

    pub fn currentYield() void {
        const ctx = current_context orelse return;
        yielded_fiber = ctx;
        saved_call = active_call;
        yield_seq +%= 1;
        var tmp: IoFiber.Context = undefined;
        _ = IoFiber.contextSwitch(&.{ .old = &tmp, .new = caller_context.? });
    }

    pub fn yieldCurrent(self: *Fiber) void {
        yielded_fiber = &self.context;
        saved_call = active_call;
        yield_seq +%= 1;
        var tmp: IoFiber.Context = undefined;
        _ = IoFiber.contextSwitch(&.{ .old = &tmp, .new = caller_context.? });
    }

    pub fn resumeYielded(data: []const u8) void {
        const target = yielded_fiber orelse return;
        yielded_result = data;
        active_call = saved_call;
        current_context = target;

        const seq_before = yield_seq;

        var resume_caller: IoFiber.Context = undefined;
        caller_context = &resume_caller;

        _ = IoFiber.contextSwitch(&.{ .old = &resume_caller, .new = target });

        if (yield_seq == seq_before) {
            current_context = null;
            caller_context = null;
            yielded_fiber = null;
            yielded_result = null;
            active_call = null;
            saved_call = null;
        } else {
            current_context = null;
            caller_context = null;
        }
    }

    pub fn yieldResult() ?[]const u8 {
        const r = yielded_result;
        yielded_result = null;
        return r;
    }

    pub fn isYielded() bool {
        return yielded_fiber != null;
    }

    /// Worker fiber 内调用：yield 当前 fiber，注册 poll 回调。
    /// worker 线程的 tick 里周期调 pollFn，返回 true 时 resume 本 fiber。
    pub fn workerYield(pollFn: *const fn (*anyopaque) bool, pollCtx: *anyopaque) void {
        parked_poll = pollFn;
        parked_poll_ctx = pollCtx;
        currentYield();
        parked_ctx = yielded_fiber;
        parked_call = saved_call;
    }

    /// Worker 线程 tick 调用：resume 一个已保存的 fiber context
    pub fn resumeContext(ctx: *IoFiber.Context) void {
        yielded_fiber = ctx;
        // saved_call should already be set by the caller or stored alongside
        resumeYielded("");
    }
};
