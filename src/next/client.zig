const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const ClientRegistry = @import("../client_registry.zig").ClientRegistry;

pub const CLIENT_READ_BUF = 16384;

fn clientDispatch(ptr: *anyopaque, res: i32) void {
    const self: *ClientStream = @ptrCast(@alignCast(ptr));
    self.dispatchCqeRes(res);
}

pub const ClientStream = struct {
    allocator: Allocator,
    ring: *linux.IoUring,
    registry: *ClientRegistry,
    id: u64,
    fd: i32,
    state: State,

    on_data: *const fn (ctx: ?*anyopaque, data: []u8) void,
    on_close: *const fn (ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,

    read_buf: []u8,
    connect_addr: linux.sockaddr = undefined,
    connect_addrlen: u32 = 0,

    write_buf: std.ArrayList(u8),
    write_offset: usize,
    writing: bool,

    pub const State = enum(u8) {
        idle,
        connecting,
        connected,
        closing,
        closed,
    };

    pub fn init(
        allocator: Allocator,
        ring: *linux.IoUring,
        registry: *ClientRegistry,
        on_data: *const fn (ctx: ?*anyopaque, data: []u8) void,
        on_close: *const fn (ctx: ?*anyopaque) void,
        callback_ctx: ?*anyopaque,
    ) !*ClientStream {
        const self = try allocator.create(ClientStream);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .ring = ring,
            .registry = registry,
            .id = 0,
            .fd = -1,
            .state = .idle,
            .on_data = on_data,
            .on_close = on_close,
            .callback_ctx = callback_ctx,
            .read_buf = try allocator.alloc(u8, CLIENT_READ_BUF),
            .write_buf = std.ArrayList(u8).empty,
            .write_offset = 0,
            .writing = false,
        };
        // 首次初始化时设置 dispatch 回调，async_server 无需知道 ClientStream 类型
        registry.dispatch_fn = &clientDispatch;
        return self;
    }

    pub fn deinit(self: *ClientStream) void {
        if (self.id != 0) {
            self.registry.remove(self.id);
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        self.allocator.free(self.read_buf);
        self.write_buf.deinit(self.allocator);
        self.state = .closed;
        self.allocator.destroy(self);
    }

    pub fn connect(self: *ClientStream, host: []const u8, port: u16) !void {
        const addr_list = try std.net.getAddressList(self.allocator, host, port);
        defer addr_list.deinit();

        const addr = addr_list.addrs[0];

        const fd = try std.posix.socket(
            addr.any.family,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
        );
        errdefer _ = linux.close(fd);

        self.fd = fd;
        self.id = self.registry.allocUserData();
        self.connect_addr = addr.any;
        self.connect_addrlen = addr.getOsSockLen();

        try self.registry.register(self.id, @ptrCast(self));
        self.state = .connecting;

        _ = std.posix.connect(fd, addr.any, addr.getOsSockLen()) catch |e| {
            if (e != error.WouldBlock) return e;
        };
        try self.submitPollOut();
    }

    fn submitPollOut(self: *ClientStream) !void {
        const sqe = self.ring.nop(self.id);
        sqe.opcode = .IORING_OP_CONNECT;
        sqe.fd = self.fd;
        sqe.addr = @intFromPtr(&self.connect_addr);
        sqe.off = self.connect_addrlen;
    }

    pub fn write(self: *ClientStream, data: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;
        try self.write_buf.appendSlice(self.allocator, data);
        if (!self.writing) {
            try self.flushWrite();
        }
    }

    fn flushWrite(self: *ClientStream) !void {
        if (self.write_offset >= self.write_buf.items.len) {
            self.write_offset = 0;
            self.write_buf.clearRetainingCapacity();
            self.writing = false;
            try self.submitRead();
            return;
        }
        const to_send = self.write_buf.items[self.write_offset..];
        const sqe = try self.ring.write(self.id, self.fd, to_send, 0);
        _ = sqe;
        self.writing = true;
    }

    fn submitRead(self: *ClientStream) !void {
        const sqe = try self.ring.read(self.id, self.fd, .{ .buffer = self.read_buf }, 0);
        _ = sqe;
    }

    pub fn close(self: *ClientStream) void {
        if (self.state == .closing or self.state == .closed) return;
        self.state = .closing;
    }

    pub fn dispatchCqe(self: *ClientStream, cqe: *const linux.io_uring_cqe) void {
        self.dispatchCqeRes(cqe.res);
    }

    fn dispatchCqeRes(self: *ClientStream, res: i32) void {
        switch (self.state) {
            .connecting => {
                if (res < 0) {
                    self.onClose();
                    return;
                }
                var so_err: i32 = 0;
                var so_len: linux.socklen_t = @sizeOf(i32);
                const rc = linux.getsockopt(self.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &so_len);
                if (rc != 0 or so_err != 0) {
                    self.onClose();
                    return;
                }
                self.state = .connected;
                self.submitRead() catch {
                    self.onClose();
                };
            },
            .connected, .closing => {
                if (res < 0) {
                    self.onClose();
                    return;
                }
                if (self.writing) {
                    // 写完成 → 继续写或切回读
                    self.write_offset += @intCast(res);
                    self.flushWrite() catch {
                        self.onClose();
                    };
                } else {
                    // 读完成 → 回调 → 冲刷写（如果有）或继续读
                    if (res == 0) {
                        self.onClose();
                        return;
                    }
                    self.on_data(self.callback_ctx, self.read_buf[0..@intCast(res)]);
                    if (self.state != .connected) return;
                    // on_data 可能已触发了 write，若未触发则继续读
                    if (!self.writing) {
                        self.submitRead() catch {
                            self.onClose();
                        };
                    }
                }
            },
            .idle, .closed => {},
        }
    }

    fn onClose(self: *ClientStream) void {
        if (self.state == .closed) return;
        self.state = .closed;
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (self.id != 0) {
            self.registry.remove(self.id);
        }
        self.on_close(self.callback_ctx);
    }
};
