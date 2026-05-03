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
        // Drain remaining tasks: exec+free user ctx, then destroy task
        while (self.pop()) |task| {
            task.exec(task.ctx, task.alloc);
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
        while (true) {
            if (@atomicLoad(bool, &pool.stop, .acquire)) return;
            if (pool.pop()) |task| {
                task.exec(task.ctx, task.alloc);
                pool.allocator.destroy(task);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

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

    /// 初始化线程池，供 Next.submit 使用。0=默认1。
    pub fn initPool4NextSubmit(self: *Next, count: u8) !void {
        const n = if (count == 0) @as(u8, 1) else count;
        const p = try self.allocator.create(WorkerPool);
        errdefer self.allocator.destroy(p);
        p.* = try WorkerPool.init(self.allocator, n);
        self.pool = p;
    }

    /// 设为默认实例，之后可调用 Next.go / Next.submit
    pub fn setDefault(self: *Next) void {
        @atomicStore(?*Next, &default_next, self, .release);
    }

    /// 静态方法——CPU 密集型：使用线程池执行
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

        // Fallback: no pool, spawn thread directly
        const Tctx = struct {
            allocator: Allocator,
            user: *T,
        };
        const tc = n.allocator.create(Tctx) catch {
            n.allocator.destroy(user);
            return;
        };
        tc.* = .{ .allocator = n.allocator, .user = user };

        const t = std.Thread.spawn(.{}, struct {
            fn run(c: *Tctx) void {
                defer c.allocator.destroy(c);
                defer c.allocator.destroy(c.user);
                const complete = struct {
                    fn done(_: ?*anyopaque, _: []const u8) void {}
                }.done;
                execFn(c.user, complete);
            }
        }.run, .{tc}) catch {
            n.allocator.destroy(tc);
            n.allocator.destroy(user);
            std.log.err("Next.submit: failed to spawn thread", .{});
            return;
        };
        n.submit_threads.append(n.allocator, t) catch {
            t.join();
            std.log.err("Next.submit: failed to track thread, joined immediately", .{});
        };
    }

    /// 静态方法——IO 线程 fiber 执行（类似 goroutine）
    /// 不切线程，推 ringbuffer → IO 线程 drain → fiber 里执行 execFn
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

    /// 静态方法 + 自定义 fiber 栈大小（同 Next.go，IO 线程 fiber）
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

                    const adapter = struct {
                        fn call(ptr: ?*anyopaque, c: *const fn (?*anyopaque, []const u8) void) void {
                            execFn(@ptrCast(@alignCast(ptr)), c);
                        }
                    }.call;

                    temp_fiber.exec(.{
                        .userCtx = u,
                        .complete = complete,
                        .execFn = adapter,
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
