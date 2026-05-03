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
threadlocal var saved_call: ?FiberCall = null;
threadlocal var yield_seq: u64 = 0;

fn trampoline() void {
    const c = active_call.?;
    c.execFn(c.userCtx, c.complete);
    // execFn 返回（complete 已被调用，或 handler 的 execFn 已结束）
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
        // 如果 fiber yield 了，上面 contextSwitch 已经返回
        // self.context 保存着 fiber 的执行点
    }

    /// 任意代码调用：yield 当前正在执行的 fiber（例如 Pipe reader 等待数据时）
    pub fn currentYield() void {
        const ctx = current_context orelse return;
        yielded_fiber = ctx;
        saved_call = active_call;
        yield_seq +%= 1;
        var tmp: IoFiber.Context = undefined;
        _ = IoFiber.contextSwitch(&.{ .old = &tmp, .new = caller_context.? });
    }

    /// fiber 内调用：yield，保存当前执行点，切回 IO 线程
    pub fn yieldCurrent(self: *Fiber) void {
        yielded_fiber = &self.context;
        saved_call = active_call;
        yield_seq +%= 1;
        var tmp: IoFiber.Context = undefined;
        _ = IoFiber.contextSwitch(&.{ .old = &tmp, .new = caller_context.? });
    }

    /// IO 线程调用：resume 之前 yield 的 fiber，传入结果 data
    pub fn resumeYielded(data: []const u8) void {
        const target = yielded_fiber orelse return;
        yielded_result = data;
        active_call = saved_call;
        current_context = target;

        const seq_before = yield_seq;

        var resume_caller: IoFiber.Context = undefined;
        caller_context = &resume_caller;

        _ = IoFiber.contextSwitch(&.{ .old = &resume_caller, .new = target });

        // fiber 可能已完成，也可能又 yield 了 — 用 yield_seq 区分
        if (yield_seq == seq_before) {
            // fiber 完成了 — 清理状态
            current_context = null;
            caller_context = null;
            yielded_fiber = null;
            yielded_result = null;
            active_call = null;
            saved_call = null;
        } else {
            // fiber 又 yield 了 — 保持状态，等下次 resume
            current_context = null;
            caller_context = null;
        }
    }

    /// fiber 内调用：取 resume 时传入的结果
    pub fn yieldResult() ?[]const u8 {
        const r = yielded_result;
        yielded_result = null;
        return r;
    }

    pub fn isYielded() bool {
        return yielded_fiber != null;
    }
};
