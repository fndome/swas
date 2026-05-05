const std = @import("std");
const Allocator = std.mem.Allocator;
const SubmitQueue = @import("queue.zig").SubmitQueue;
const Item = @import("queue.zig").Item;
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;

const TaskCtx = struct {
    next: *Next,
    userCtx: ?*anyopaque,
    stack_size: u32,
};

var default_next: ?*Next = null;

/// ── WorkerPool ──────────────────────────────────────────
const PoolTask = struct {
    next: ?*PoolTask,
    exec: *const fn (?*anyopaque, Allocator) void,
    ctx: ?*anyopaque,
    alloc: Allocator,
};

const ParkedTask = struct {
    fiber_ctx: std.Io.fiber.Context,
    task: *PoolTask,
    poll_fn: *const fn (*anyopaque) bool,
    poll_ctx: *anyopaque,
};

const FIBER_STACK: u32 = 65536;

fn makeFiberCall(task: *PoolTask) @import("fiber.zig").FiberCall {
    return .{
        .userCtx = @ptrCast(task),
        .complete = struct {
            fn done(_: ?*anyopaque, _: []const u8) void {}
        }.done,
        .execFn = struct {
            fn run(c: ?*anyopaque, _: *const fn (?*anyopaque, []const u8) void) void {
                const t: *PoolTask = @ptrCast(@alignCast(c));
                t.exec(t.ctx, t.alloc);
            }
        }.run,
    };
}

const WorkerPool = struct {
    allocator: Allocator,
    workers: []std.Thread,
    head: ?*PoolTask,
    tail: ?*PoolTask,
    spinlock: bool,
    stop: bool align(@alignOf(u8)),

    fn acquire(self: *WorkerPool) void {
        while (@atomicRmw(bool, &self.spinlock, .Xchg, true, .acquire)) {
            std.Thread.yield() catch {};
        }
    }

    fn release(self: *WorkerPool) void {
        @atomicStore(bool, &self.spinlock, false, .release);
    }

    fn init(allocator: Allocator, count: u8) !WorkerPool {
        const workers = try allocator.alloc(std.Thread, count);
        var pool = WorkerPool{
            .allocator = allocator,
            .workers = workers,
            .head = null,
            .tail = null,
            .spinlock = false,
            .stop = false,
        };
        for (workers, 0..) |*w, i| {
            w.* = std.Thread.spawn(.{}, workerLoop, .{ &pool, @as(u8, @intCast(i)) }) catch {
                pool.stop = true;
                for (workers[0..i]) |pw| pw.join();
                allocator.free(workers);
                return error.ThreadSpawnFailed;
            };
        }
        return pool;
    }

    fn deinit(self: *WorkerPool) void {
        self.acquire();
        @atomicStore(bool, &self.stop, true, .release);
        self.release();
        while (self.pop()) |task| {
            self.allocator.destroy(task);
        }
        for (self.workers) |w| w.join();
        self.allocator.free(self.workers);
    }

    fn submit(self: *WorkerPool, task: *PoolTask) void {
        self.acquire();
        if (self.tail) |t| {
            t.next = task;
        } else {
            self.head = task;
        }
        self.tail = task;
        self.release();
    }

    fn pop(self: *WorkerPool) ?*PoolTask {
        self.acquire();
        const task = self.head orelse {
            self.release();
            return null;
        };
        self.head = task.next;
        if (self.head == null) self.tail = null;
        self.release();
        task.next = null;
        return task;
    }

    fn workerLoop(pool: *WorkerPool, _: u8) void {
        var parked = std.ArrayList(ParkedTask).empty;

        while (true) {
            if (@atomicLoad(bool, &pool.stop, .acquire)) return;

            var i: usize = 0;
            while (i < parked.items.len) {
                if (parked.items[i].poll_fn(parked.items[i].poll_ctx)) {
                    var pt = parked.swapRemove(i);
                    resumeParked(pool, &pt, &parked);
                } else {
                    i += 1;
                }
            }

            if (pool.pop()) |task| {
                runTask(pool, task, &parked);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

fn runTask(pool: *WorkerPool, task: *PoolTask, parked: *std.ArrayList(ParkedTask)) void {
    var stack: [FIBER_STACK]u8 = undefined;
    var fiber = Fiber.init(&stack);
    const call = makeFiberCall(task);
    fiber.exec(call);

    if (Fiber.isYielded()) {
        const ctx = @import("fiber.zig").parked_ctx orelse return;
        const poll = @import("fiber.zig").parked_poll orelse return;
        const poll_ctx = @import("fiber.zig").parked_poll_ctx orelse return;
        parked.append(pool.allocator, .{
            .fiber_ctx = ctx.*,
            .task = task,
            .poll_fn = poll,
            .poll_ctx = poll_ctx,
        }) catch {
            @import("fiber.zig").saved_call = call;
            Fiber.resumeContext(ctx);
        };
        @import("fiber.zig").parked_ctx = null;
        @import("fiber.zig").parked_poll = null;
        @import("fiber.zig").parked_poll_ctx = null;
    } else {
        pool.allocator.destroy(task);
    }
}

fn resumeParked(pool: *WorkerPool, pt: *ParkedTask, parked: *std.ArrayList(ParkedTask)) void {
    @import("fiber.zig").saved_call = makeFiberCall(pt.task);
    Fiber.resumeContext(&pt.fiber_ctx);

    if (Fiber.isYielded()) {
        const ctx = @import("fiber.zig").parked_ctx orelse return;
        const poll = @import("fiber.zig").parked_poll orelse return;
        const poll_ctx = @import("fiber.zig").parked_poll_ctx orelse return;
        parked.append(pool.allocator, .{
            .fiber_ctx = ctx.*,
            .task = pt.task,
            .poll_fn = poll,
            .poll_ctx = poll_ctx,
        }) catch {};
        @import("fiber.zig").parked_ctx = null;
        @import("fiber.zig").parked_poll = null;
        @import("fiber.zig").parked_poll_ctx = null;
    } else {
        pool.allocator.destroy(pt.task);
    }
}

/// ── Next ──────────────────────────────────────────────────
pub const Next = struct {
    ringbuffer: *SubmitQueue,
    allocator: Allocator,
    default_stack_size: u32,
    pool: ?*WorkerPool,
    submit_threads: std.ArrayList(std.Thread),

    pub fn init(alloc: Allocator, stack_size: u32) Next {
        const q = alloc.create(SubmitQueue) catch @panic("OOM");
        q.* = SubmitQueue.init();
        return .{
            .ringbuffer = q,
            .allocator = alloc,
            .default_stack_size = stack_size,
            .pool = null,
            .submit_threads = std.ArrayList(std.Thread).initCapacity(alloc, 0) catch @panic("OOM"),
        };
    }

    pub fn deinit(self: *Next) void {
        if (self.pool) |p| p.deinit();
        for (self.submit_threads.items) |t| t.join();
        self.submit_threads.deinit(self.allocator);
        self.allocator.destroy(self.ringbuffer);
    }

    pub fn initPool4NextSubmit(self: *Next, count: u8) !void {
        if (self.pool != null) return;
        const n = if (count == 0) @as(u8, 1) else count;
        const p = try self.allocator.create(WorkerPool);
        errdefer self.allocator.destroy(p);
        p.* = try WorkerPool.init(self.allocator, n);
        self.pool = p;
    }

    pub fn setDefault(self: *Next) void {
        @atomicStore(?*Next, &default_next, self, .release);
    }

    pub fn submit(
        comptime T: type,
        ctx: T,
        comptime execFn: fn (*T, *const fn (?*anyopaque, []const u8) void) void,
    ) void {
        const n = @atomicLoad(?*Next, &default_next, .acquire) orelse {
            std.log.err("Next.submit: no default Next instance set", .{});
            return;
        };
        const user = n.allocator.create(T) catch return;
        user.* = ctx;

        if (n.pool) |p| {
            const task = n.allocator.create(PoolTask) catch {
                n.allocator.destroy(user);
                return;
            };
            task.* = .{
                .next = null,
                .exec = struct {
                    fn run(ctx2: ?*anyopaque, alloc: Allocator) void {
                        const u: *T = @ptrCast(@alignCast(ctx2));
                        defer alloc.destroy(u);
                        const complete = struct {
                            fn done(_: ?*anyopaque, _: []const u8) void {}
                        }.done;
                        execFn(u, complete);
                    }
                }.run,
                .ctx = user,
                .alloc = n.allocator,
            };
            p.submit(task);
            return;
        }

        // No pool — log error, destroy user ctx
        std.log.err("Next.submit: no worker pool configured. Call initPool4NextSubmit(n) first.", .{});
        n.allocator.destroy(user);
    }

    pub fn go(
        comptime T: type,
        ctx: T,
        comptime execFn: fn (*T, *const fn (?*anyopaque, []const u8) void) void,
    ) void {
        const n = @atomicLoad(?*Next, &default_next, .acquire) orelse {
            std.log.err("Next.go: no default Next instance set", .{});
            return;
        };
        n.push(T, ctx, execFn, n.default_stack_size);
    }

    pub fn goWithStackConfigurable(
        comptime T: type,
        ctx: T,
        comptime execFn: fn (*T, *const fn (?*anyopaque, []const u8) void) void,
        stack_size: u32,
    ) void {
        const n = @atomicLoad(?*Next, &default_next, .acquire) orelse {
            std.log.err("Next.goWithStackConfigurable: no default Next instance set", .{});
            return;
        };
        n.push(T, ctx, execFn, stack_size);
    }

    pub fn push(
        self: *Next,
        comptime T: type,
        ctx: T,
        comptime execFn: fn (*T, *const fn (?*anyopaque, []const u8) void) void,
        stack_size: u32,
    ) void {
        const user = self.allocator.create(T) catch return;
        user.* = ctx;

        const gc = self.allocator.create(TaskCtx) catch {
            self.allocator.destroy(user);
            return;
        };
        gc.* = .{ .next = self, .userCtx = user, .stack_size = stack_size };

        if (!self.ringbuffer.push(.{
            .ctx = gc,
            .execute = struct {
                fn exec(caller_ctx: ?*anyopaque, complete: *const fn (?*anyopaque, []const u8) void) void {
                    const g: *TaskCtx = @ptrCast(@alignCast(caller_ctx));
                    const u: *T = @ptrCast(@alignCast(g.userCtx));

                    const stack = g.next.allocator.alloc(u8, g.stack_size) catch {
                        g.next.allocator.destroy(u);
                        g.next.allocator.destroy(g);
                        return;
                    };

                    var temp_fiber = Fiber.init(stack);
                    temp_fiber.exec(.{
                        .userCtx = u,
                        .complete = complete,
                        .execFn = struct {
                            fn call(ptr: ?*anyopaque, c: *const fn (?*anyopaque, []const u8) void) void {
                                execFn(@ptrCast(@alignCast(ptr)), c);
                            }
                        }.call,
                    });

                    if (Fiber.isYielded()) {
                        const CleanupData = struct {
                            g: *TaskCtx,
                            u: *T,
                            stack: []u8,
                            allocator: Allocator,

                            fn free(ptr: *anyopaque) void {
                                const data: *@This() = @ptrCast(@alignCast(ptr));
                                data.allocator.destroy(data.u);
                                data.allocator.free(data.stack);
                                data.allocator.destroy(data.g);
                                data.allocator.destroy(data);
                            }
                        };
                        const cd = g.next.allocator.create(CleanupData) catch {
                            g.next.allocator.destroy(u);
                            g.next.allocator.free(stack);
                            g.next.allocator.destroy(g);
                            return;
                        };
                        cd.* = .{ .g = g, .u = u, .stack = stack, .allocator = g.next.allocator };
                        fiber_mod.yield_cleanup = .{
                            .data = @ptrCast(cd),
                            .free_fn = CleanupData.free,
                        };
                    } else {
                        g.next.allocator.destroy(u);
                        g.next.allocator.free(stack);
                        g.next.allocator.destroy(g);
                    }
                }
            }.exec,
            .on_complete = struct {
                fn done(_: ?*anyopaque, _: []const u8) void {}
            }.done,
        })) {
            self.allocator.destroy(gc);
            self.allocator.destroy(user);
            std.log.err("Next.push: ringbuffer full, task dropped", .{});
        }
    }

    /// ── Next.chainGoSubmit ─────────────────────────────────
    ///
    /// 编程模型：Go（IO 线程 fiber）→ Submit（worker 池）→ 响应。
    /// 同一 Ctx 流经两个阶段，无需手动分配 DeferredResponse。
    ///
    /// 用法（handler 中一行搞定）：
    ///   try Next.chainGoSubmit(ctx, myCtx, execDb, execCompute, sendJson);
    ///
    ///   execDb(Ctx):       IO 线程 fiber 执行（DB io_uring、异步 I/O）
    ///   execCompute(Ctx):  worker 池执行（CPU 密集）
    ///   sendJson(Ctx, DeferredResponse):  构建并发送响应
    pub fn chainGoSubmit(
        comptime T: type,
        http_ctx: *Context,
        user_ctx: T,
        comptime execGo: fn (*T) void,
        comptime execSubmit: fn (*T) void,
        comptime respond: fn (*T, *DeferredResponse) void,
    ) !void {
        const s = http_ctx.server orelse return;
        const server: *AsyncServer = @ptrCast(@alignCast(s));
        const alloc = http_ctx.allocator;

        const resp = try alloc.create(DeferredResponse);
        errdefer alloc.destroy(resp);
        resp.* = .{ .server = server, .conn_id = http_ctx.conn_id, .allocator = alloc };

        const wrap = try alloc.create(ChainWrap(T));
        errdefer alloc.destroy(wrap);
        wrap.* = .{ .user = user_ctx, .resp = resp, .allocator = alloc, .next = default_next };

        http_ctx.deferred = true;

        go(
            ChainWrap(T),
            wrap.*,
            struct {
                fn execGoWrapper(
                    w: *ChainWrap(T),
                    complete: *const fn (?*anyopaque, []const u8) void,
                ) void {
                    execGo(&w.user);

                    // 将 Ctx 的副本交到 worker 池
                    const submit_ctx = w.allocator.create(ChainSubmitCtx(T)) catch {
                        w.resp.json(500, "{\"error\":\"OOM\"}");
                        w.allocator.destroy(w.resp);
                        w.allocator.destroy(w);
                        complete(w, "");
                        return;
                    };
                    submit_ctx.* = .{
                        .user = w.user,
                        .resp = w.resp,
                        .allocator = w.allocator,
                    };

                    submit(
                        ChainSubmitCtx(T),
                        submit_ctx.*,
                        struct {
                            fn execSubmitWrapper(
                                sc: *ChainSubmitCtx(T),
                                _: *const fn (?*anyopaque, []const u8) void,
                            ) void {
                                defer sc.allocator.destroy(sc.resp);
                                execSubmit(&sc.user);
                                respond(&sc.user, sc.resp);
                            }
                        }.execSubmitWrapper,
                    );

                    w.allocator.destroy(w);
                    complete(w, "");
                }
            }.execGoWrapper,
        );
    }

    const DeferredResponse = @import("../root.zig").DeferredResponse;
    const Context = @import("../http/context.zig").Context;
    const AsyncServer = @import("../http/async_server.zig").AsyncServer;
};

fn ChainWrap(comptime T: type) type {
    return struct {
        user: T,
        resp: *Next.DeferredResponse,
        allocator: Allocator,
        next: ?*Next,
    };
}

fn ChainSubmitCtx(comptime T: type) type {
    return struct {
        user: T,
        resp: *Next.DeferredResponse,
        allocator: Allocator,
    };
}
