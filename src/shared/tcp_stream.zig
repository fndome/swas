const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const RingShared = @import("ring_shared.zig").RingShared;
const DnsResolver = @import("../dns/resolver.zig").DnsResolver;

pub const CLIENT_READ_BUF = 16384;

fn clientDispatch(ptr: *anyopaque, res: i32) void {
    const self: *RingSharedClient = @ptrCast(@alignCast(ptr));
    self.dispatchCqeRes(res);
}

pub const RingSharedClient = struct {
    allocator: Allocator,
    rs: RingShared,
    id: u64,
    fd: i32,
    state: State,

    on_data: *const fn (ctx: ?*anyopaque, data: []u8) void,
    on_close: *const fn (ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,

    read_buf: []u8,
    conn_errno: i32 = 0, // connect CQE 错误码 (0=成功, -ETIMEDOUT=超时)
    connect_addr: linux.sockaddr = undefined,
    _connect_addrlen: u32 = 0,

    write_buf: std.ArrayList(u8),
    write_offset: usize,
    writing: bool,

    dns: ?*DnsResolver,
    fixed_index: u16 = 0xFFFF,

    pub const State = enum(u8) {
        idle,
        connecting,
        connected,
        closing,
        closed,
    };

    pub fn init(
        allocator: Allocator,
        rs: RingShared,
        on_data: *const fn (ctx: ?*anyopaque, data: []u8) void,
        on_close: *const fn (ctx: ?*anyopaque) void,
        callback_ctx: ?*anyopaque,
        dns: ?*DnsResolver,
    ) !*RingSharedClient {
        const self = try allocator.create(RingSharedClient);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .rs = rs,
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
            .dns = dns,
        };
        return self;
    }

    pub fn deinit(self: *RingSharedClient) void {
        if (self.id != 0) {
            self.rs.remove(self.id);
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

    pub fn connect(self: *RingSharedClient, host: []const u8, port: u16) !void {
        const ip = parseIpv4(host) catch blk: {
            if (self.dns) |dns| {
                break :blk dns.resolve(host) catch return error.InvalidHost;
            }
            return error.InvalidHost;
        };
        self.connectRaw(ip, port) catch |err| return err;
    }

    pub fn connectRaw(self: *RingSharedClient, ip: u32, port: u16) !void {
        self.connectRawTimeout(ip, port, 5000); // default 5s
    }

    pub fn connectRawTimeout(self: *RingSharedClient, ip: u32, port: u16, timeout_ms: u32) !void {
        const raw_fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        const fd: i32 = @intCast(raw_fd);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = linux.close(fd);

        var addr_in = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(port),
            .addr = ip,
            .zero = [_]u8{0} ** 8,
        };
        const addr: *linux.sockaddr = @ptrCast(&addr_in);

        self.fd = fd;
        self.id = self.rs.allocUserData();
        self.connect_addr = addr.*;
        self._connect_addrlen = @sizeOf(linux.sockaddr.in);

        self.rs.register(self.id, @ptrCast(self), &clientDispatch) catch {
            self.rs.remove(self.id);
            return error.RegisterFailed;
        };
        self.state = .connecting;

        _ = linux.connect(fd, @ptrCast(&addr_in), @sizeOf(linux.sockaddr.in));
        try self.submitPollOut(timeout_ms);
    }

    fn submitPollOut(self: *RingSharedClient, timeout_ms: u32) !void {
        const sqe = self.rs.ringPtr().nop(self.id) catch return;
        sqe.opcode = @enumFromInt(27); // IORING_OP_CONNECT
        sqe.fd = self.fd;
        sqe.addr = @intFromPtr(&self.connect_addr);
        sqe.off = self._connect_addrlen;
        if (timeout_ms > 0) {
            sqe.flags |= linux.IOSQE_IO_LINK; // 链接下一个 SQE (LINK_TIMEOUT)
        }
        _ = self.rs.ringPtr().submit() catch {};

        if (timeout_ms > 0) {
            const tsqe = self.rs.ringPtr().nop(0) catch return;
            tsqe.opcode = @enumFromInt(15); // IORING_OP_LINK_TIMEOUT
            var ts = linux.__kernel_timespec{
                .tv_sec = @intCast(timeout_ms / 1000),
                .tv_nsec = @intCast((timeout_ms % 1000) * 1_000_000),
            };
            tsqe.addr = @intFromPtr(&ts);
            tsqe.len = 1;
            _ = self.rs.ringPtr().submit() catch {};
        }
    }

    pub fn write(self: *RingSharedClient, data: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;
        try self.write_buf.appendSlice(self.allocator, data);
        if (!self.writing) {
            try self.flushWrite();
        }
    }

    fn flushWrite(self: *RingSharedClient) !void {
        if (self.write_offset >= self.write_buf.items.len) {
            self.write_offset = 0;
            self.write_buf.clearRetainingCapacity();
            self.writing = false;
            try self.submitRead();
            return;
        }
        const to_send = self.write_buf.items[self.write_offset..];
        const use_fixed = self.fixed_index != 0xFFFF;
        const fd_or_idx = if (use_fixed) @as(i32, @intCast(self.fixed_index)) else self.fd;
        const sqe = try self.rs.ringPtr().write(self.id, fd_or_idx, to_send, 0);
        if (use_fixed) sqe.flags |= linux.IOSQE_FIXED_FILE;
        self.writing = true;
    }

    fn submitRead(self: *RingSharedClient) !void {
        const use_fixed = self.fixed_index != 0xFFFF;
        const fd_or_idx = if (use_fixed) @as(i32, @intCast(self.fixed_index)) else self.fd;
        const sqe = try self.rs.ringPtr().read(self.id, fd_or_idx, .{ .buffer = self.read_buf }, 0);
        if (use_fixed) sqe.flags |= linux.IOSQE_FIXED_FILE;
    }

    pub fn close(self: *RingSharedClient) void {
        if (self.state == .closing or self.state == .closed) return;
        self.state = .closing;
    }

    pub fn dispatchCqe(self: *RingSharedClient, cqe: *const linux.io_uring_cqe) void {
        self.dispatchCqeRes(cqe.res);
    }

    fn dispatchCqeRes(self: *RingSharedClient, res: i32) void {
        switch (self.state) {
            .connecting => {
                if (res < 0) {
                    self.conn_errno = res;
                    self.onClose();
                    return;
                }
                self.conn_errno = 0;
                var so_err: i32 = 0;
                var so_len: linux.socklen_t = @sizeOf(i32);
                const rc = linux.getsockopt(self.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &so_len);
                if (rc != 0 or so_err != 0) {
                    self.onClose();
                    return;
                }
                self.state = .connected;
                // Disable Nagle — low-latency microservice calls
                const one: i32 = 1;
                _ = linux.setsockopt(self.fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(i32));
                // Register as fixed file to avoid kernel fd lookup per I/O
                if (self.rs.ringPtr().register_files_sparse(1)) {
                    if (self.rs.ringPtr().register_files_update(0, &[_]linux.fd_t{self.fd})) {
                        self.fixed_index = 0;
                    } else |_| {}
                } else |_| {}
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
                    self.write_offset += @intCast(res);
                    self.flushWrite() catch {
                        self.onClose();
                    };
                } else {
                    if (res == 0) {
                        self.onClose();
                        return;
                    }
                    self.on_data(self.callback_ctx, self.read_buf[0..@intCast(res)]);
                    if (self.state != .connected) return;
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

    fn onClose(self: *RingSharedClient) void {
        if (self.state == .closed) return;
        self.state = .closed;
        if (self.fixed_index != 0xFFFF) {
            _ = self.rs.ringPtr().register_files_update(self.fixed_index, &[_]linux.fd_t{-1}) catch {};
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (self.id != 0) {
            self.rs.remove(self.id);
        }
        self.on_close(self.callback_ctx);
    }
};

fn parseIpv4(ip_str: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, ip_str, '.');
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidHost;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidHost;
    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        (@as(u32, octets[3]));
}
