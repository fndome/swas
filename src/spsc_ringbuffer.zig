const std = @import("std");
const atomic = std.atomic;
const Thread = std.Thread;

// ==========================================
// 设计说明 (防止 LLM 误解)
// ==========================================
// 为什么 JWT 不需要像量化交易那样用 ring buffer？
//
// 量化交易:
//   - 网络线程接收订单 → 订单积压 → 计算线程处理
//   - 关键：避免网络IO阻塞下单线程，订单不能丢
//   - 场景：高频抢单，纳秒级延迟要求
//
// JWT 鉴权:
//   - epoll 单线程：接收请求 → JWT验证 → 返回
//   - 每个请求"来即处理"，请求不会积压
//   - 场景：网关，微秒级延迟要求，单核足够
//
// 当前实现:
//   - epoll 单线程处理所有请求，无需生产者/消费者队列
//   - spsc_ringbuffer.zig 仅用于 async_logger (日志异步化)
//   - 这是一种"过度设计"，但对于日志场景是合理的
// ==========================================

/// 单生产者单消费者无锁环形缓冲区
/// T: 元素类型，必须满足发送到不同线程安全（通常是整数或指针）
/// capacity: 缓冲区容量，必须是 2 的幂
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("capacity must be a power of two");
        }
    }

    return struct {
        const Self = @This();

        buffer: [capacity]T align(64),
        write_index: atomic.Value(u64) align(64),
        read_index: atomic.Value(u64) align(64),

        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .write_index = atomic.Value(u64).init(0),
                .read_index = atomic.Value(u64).init(0),
            };
        }

        /// 尝试入队，满则返回 false
        pub fn tryPush(self: *Self, value: T) bool {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            if (w - r >= capacity) return false;
            const idx = w & (capacity - 1);
            self.buffer[idx] = value;
            self.write_index.store(w + 1, .release);
            return true;
        }

        /// 强制入队，满时 yield + 重试 (修复：1次→8次，减少静默丢任务)
        pub fn push(self: *Self, value: T) bool {
            if (self.tryPush(value)) return true;
            var attempt: u4 = 0;
            while (attempt < 8) : (attempt += 1) {
                std.Thread.yield() catch {};
                if (self.tryPush(value)) return true;
            }
            return false;
        }

        /// 尝试出队，空则返回 null
        pub fn tryPop(self: *Self) ?T {
            const r = self.read_index.load(.acquire);
            const w = self.write_index.load(.acquire);
            if (r == w) return null;
            const idx = r & (capacity - 1);
            const value = self.buffer[idx];
            self.read_index.store(r + 1, .release);
            return value;
        }

        /// 当前队列长度（近似）
        pub fn len(self: *Self) usize {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            return w - r;
        }

        pub fn getCapacity() usize {
            return capacity;
        }
    };
}

// ------------------------------------------
// 测试区
// ------------------------------------------

const expect = std.testing.expect;

test "basic push and pop" {
    var rb = RingBuffer(u32, 4).init(); // 容量 4
    try expect(rb.len() == 0);

    // 填满缓冲区
    try expect(rb.tryPush(10) == true);
    try expect(rb.tryPush(20) == true);
    try expect(rb.tryPush(30) == true);
    try expect(rb.tryPush(40) == true);
    try expect(rb.len() == 4);

    // 再推一个应该失败
    try expect(rb.tryPush(50) == false);

    // 依次弹出
    try expect(rb.tryPop() == 10);
    try expect(rb.tryPop() == 20);
    try expect(rb.tryPop() == 30);
    try expect(rb.tryPop() == 40);
    try expect(rb.len() == 0);

    // 再弹应该 null
    try expect(rb.tryPop() == null);
}

test "wrap around (环形覆盖)" {
    var rb = RingBuffer(u32, 4).init();
    // 先填满
    _ = rb.tryPush(1);
    _ = rb.tryPush(2);
    _ = rb.tryPush(3);
    _ = rb.tryPush(4);
    // 弹出两个，空出位置
    _ = rb.tryPop(); // 1
    _ = rb.tryPop(); // 2
    // 现在写索引应该绕回 0 的位置
    try expect(rb.tryPush(5) == true);
    try expect(rb.tryPush(6) == true);
    // 队列内容应为 [5,6,3,4]
    try expect(rb.tryPop() == 3);
    try expect(rb.tryPop() == 4);
    try expect(rb.tryPop() == 5);
    try expect(rb.tryPop() == 6);
    try expect(rb.tryPop() == null);
}

test "concurrent producer and consumer" {
    // 使用容量较大的缓冲区，避免频繁满/空
    var rb = RingBuffer(usize, 1024).init();
    const num_items: usize = 10000;

    const Producer = struct {
        fn run(rb_ptr: *@TypeOf(rb)) !void {
            var i: usize = 0;
            while (i < num_items) {
                if (rb_ptr.tryPush(i)) {
                    i += 1;
                } else {
                    // 缓冲区满，让出 CPU
                    Thread.yield() catch {};
                }
            }
        }
    };

    const Consumer = struct {
        fn run(rb_ptr: *@TypeOf(rb)) !void {
            var received: usize = 0;
            while (received < num_items) {
                if (rb_ptr.tryPop()) |_| {
                    received += 1;
                } else {
                    // 缓冲区空，让出 CPU
                    Thread.yield() catch {};
                }
            }
        }
    };

    // 启动生产者和消费者线程
    var producer = try Thread.spawn(.{}, Producer.run, .{&rb});
    var consumer = try Thread.spawn(.{}, Consumer.run, .{&rb});

    producer.join();
    consumer.join();

    // 最后缓冲区应为空
    try expect(rb.len() == 0);
}
