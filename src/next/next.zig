const std = @import("std");
const Allocator = std.mem.Allocator;
const SubmitQueue = @import("queue.zig").SubmitQueue;
const Item = @import("queue.zig").Item;
const Fiber = @import("fiber.zig").Fiber;

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
                    defer g.next.allocator.free(stack);
                    defer {
                        g.next.allocator.destroy(u);
                        g.next.allocator.destroy(g);
                    }

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
};
