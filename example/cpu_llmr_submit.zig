/// ── Next.submit 切线程做 CPU 重活（如 LLM 推理）──
///
/// Next.submit: 线程池执行，切线程。main 里需要:
///   try server.initPool4NextSubmit(2);
///
/// ⚠️ 只有 CPU 密集 / 阻塞 I/O 才用 submit。
///    io_uring 场景用 Next.go，不要切线程。
///
/// 用法：server.POST("/infer", inferHandler)

const std = @import("std");

const swas = @import("swas");
const Context = swas.Context;
const DeferredResponse = swas.DeferredResponse;
const AsyncServer = swas.AsyncServer;
const Next = swas.Next;

const InferCtx = struct {
    allocator: std.mem.Allocator,
    resp: *DeferredResponse,
    prompt: []const u8,
};

/// execFn 在线程池线程上执行（不在 IO 线程）
fn inferExec(c: *InferCtx, complete: *const fn (?*anyopaque, []const u8) void) void {
    defer c.allocator.destroy(c);
    defer c.allocator.destroy(c.resp);

    // ── CPU 重活：模型推理 ──
    // const output = llm.generate(c.prompt);   // 阻塞几十秒

    const output = std.fmt.allocPrint(c.allocator,
        "{{\"reply\":\"Hello, you said: {s}\"}}", .{c.prompt}
    ) catch "{\"error\":\"oom\"}";
    defer c.allocator.free(output);

    c.resp.json(200, output);
    complete(c, "");
}

pub fn inferHandler(allocator: std.mem.Allocator, ctx: *Context) anyerror!void {
    const s: *AsyncServer = @ptrCast(@alignCast(ctx.server.?));

    const resp = try allocator.create(DeferredResponse);
    resp.* = .{ .server = s, .conn_id = ctx.conn_id, .allocator = allocator };

    ctx.deferred = true;
    Next.submit(InferCtx, .{
        .allocator = allocator,
        .resp = resp,
        .prompt = "Hello, how are you?",
    }, inferExec);
}
