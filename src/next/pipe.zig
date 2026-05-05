const std = @import("std");
const Allocator = std.mem.Allocator;
const Fiber = @import("fiber.zig").Fiber;
const RingSharedClient = @import("../tcp_stream.zig").RingSharedClient;

/// Pipe: 将 RingSharedClient 的推模型（on_data 回调）适配为拉模型（reader.read/writer.write）。
///
/// 协议库（pgz / myzql / nats）在 fiber 内调用 reader.read()，
/// 无数据时通过 fiber yield 挂起，RingSharedClient.on_data → feed() → fiber resume。
/// 全程跑在 IO 线程，零锁，零 worker 线程。
pub const Pipe = struct {
    allocator: Allocator,
    stream: *RingSharedClient,

    read_buf: std.ArrayList(u8),
    write_buf: std.ArrayList(u8),

    pub fn init(allocator: Allocator, stream: *RingSharedClient) !Pipe {
        return Pipe{
            .allocator = allocator,
            .stream = stream,
            .read_buf = std.ArrayList(u8).empty,
            .write_buf = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Pipe) void {
        self.read_buf.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
    }

    pub fn reader(self: *Pipe) Reader {
        return Reader{ .pipe = self };
    }

    pub fn writer(self: *Pipe) Writer {
        return Writer{ .pipe = self };
    }

    /// RingSharedClient.on_data 回调入口：喂数据进读缓冲区，唤醒等待的 reader
    pub fn feed(self: *Pipe, data: []const u8) !void {
        try self.read_buf.appendSlice(self.allocator, data);
        if (Fiber.isYielded()) {
            Fiber.resumeYielded("");
        }
    }

    /// 冲刷写缓冲区到 RingSharedClient
    pub fn flushWrite(self: *Pipe) !void {
        if (self.write_buf.items.len == 0) return;
        try self.stream.write(self.write_buf.items);
        self.write_buf.clearRetainingCapacity();
    }

    /// 重置所有缓冲区（连接断开/重连时调用）
    pub fn reset(self: *Pipe) void {
        self.read_buf.clearRetainingCapacity();
        self.write_buf.clearRetainingCapacity();
    }

    pub const Reader = struct {
        pipe: *Pipe,

        pub fn read(self: Reader, dest: []u8) !usize {
            if (self.pipe.read_buf.items.len > 0) {
                const n = @min(dest.len, self.pipe.read_buf.items.len);
                @memcpy(dest[0..n], self.pipe.read_buf.items[0..n]);
                self.pipe.read_buf.replaceRange(self.pipe.allocator, 0, n, &.{}) catch unreachable;
                return n;
            }
            // 无数据 → yield fiber，等 RingSharedClient feed() 唤醒
            Fiber.currentYield();
            // 醒来后缓冲区必有数据（feed 已填充）
            if (self.pipe.read_buf.items.len == 0) return error.Closed;
            const n = @min(dest.len, self.pipe.read_buf.items.len);
            @memcpy(dest[0..n], self.pipe.read_buf.items[0..n]);
            self.pipe.read_buf.replaceRange(self.pipe.allocator, 0, n, &.{}) catch unreachable;
            return n;
        }

        /// 读满 dest，否则 yield 等待
        pub fn readAll(self: Reader, dest: []u8) !void {
            var offset: usize = 0;
            while (offset < dest.len) {
                const n = try self.read(dest[offset..]);
                if (n == 0) return error.Closed;
                offset += n;
            }
        }
    };

    pub const Writer = struct {
        pipe: *Pipe,

        pub fn write(self: Writer, data: []const u8) !usize {
            try self.pipe.write_buf.appendSlice(self.pipe.allocator, data);
            return data.len;
        }

        pub fn writeAll(self: Writer, data: []const u8) !void {
            _ = try self.write(data);
        }

        pub fn flush(self: Writer) !void {
            try self.pipe.flushWrite();
        }
    };
};
