// im_bench.zig — sws AsyncServer HTTP throughput benchmark
const std = @import("std");
const linux = std.os.linux;
const sws = @import("sws");
const AsyncServer = sws.AsyncServer;

const PORT = 19090;
const CONNS = 50;
const REQS_PER_CONN = 1000;

fn benchHandler(allocator: std.mem.Allocator, ctx: *sws.Context) anyerror!void {
    _ = allocator;
    try ctx.rawJson(200, "{\"ok\":true}");
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const addr = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{PORT});
    defer alloc.free(addr);

    var io_backend = std.Io.Threaded.init(alloc, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var server = try AsyncServer.init(alloc, io, addr, null, 64);
    defer server.deinit();
    try server.GET("/bench", benchHandler);
    server.installSigterm();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *AsyncServer) void {
            s.run() catch @panic("server run failed");
        }
    }.run, .{&server});

    _ = linux.nanosleep(&linux.timespec{ .sec = 0, .nsec = 300_000_000 }, null);

    const t0 = nowMs();

    // connect clients
    var fds: [CONNS]i32 = [_]i32{0} ** CONNS;
    for (&fds) |*fd| {
        const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (raw < 0) continue;
        const fd_val: i32 = @intCast(raw);
        const sa = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(@as(u16, PORT)),
            .addr = 0x0100007F,
            .zero = [_]u8{0} ** 8,
        };
        if (linux.connect(fd_val, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)) == 0) {
            fd.* = fd_val;
        } else {
            _ = linux.close(fd_val);
        }
    }

    const t_conn = nowMs();

    // send requests
    var buf: [4096]u8 = undefined;
    const req = "GET /bench HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
    var sent: usize = 0;
    var recv: usize = 0;

    const t_send0 = nowMs();
    while (sent < CONNS * REQS_PER_CONN) : (sent += 1) {
        const fd = fds[sent % CONNS];
        if (fd == 0) continue;
        _ = linux.write(fd, req, req.len);
        // drain between rounds
        if (sent % (CONNS * 10) == 0) {
            for (&fds) |dfd| {
                if (dfd == 0) continue;
                const n = linux.read(dfd, &buf, buf.len);
                if (n > 0) recv += 1;
            }
        }
    }
    // final drain
    for (&fds) |dfd| {
        if (dfd == 0) continue;
        var tmp: [4096]u8 = undefined;
        while (linux.read(dfd, &tmp, tmp.len) > 0) {
            recv += 1;
        }
        _ = linux.close(dfd);
    }

    const t_end = nowMs();
    server.stop();
    server_thread.join();

    const conn_ms = t_conn - t0;
    const send_ms: i64 = @max(t_end - t_send0, 1);
    const total = CONNS * REQS_PER_CONN;
    const per_sec = @divTrunc(@as(i64, @intCast(total)) * 1000, send_ms);

    std.debug.print("\n", .{});
    std.debug.print("  connections: {d} ({d} ms)\n", .{ CONNS, conn_ms });
    std.debug.print("  sent:        {d} req in {d} ms\n", .{ total, send_ms });
    std.debug.print("  recv:        {d} resp\n", .{recv});
    std.debug.print("  throughput:  {d} req/s\n", .{per_sec});
    std.debug.print("\n", .{});
}
