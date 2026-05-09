// im_bench.zig — sws AsyncServer HTTP throughput benchmark
/// io_wq_acct.lock remove
/// sysctl -w net.ipv4.tcp_tw_reuse=1
/// IORING_SETUP_SINGLE_ISSUER
/// IORING_SETUP_COOP_TASKRUN
/// echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
/// taskset -c 0,1
/// SWS_BENCH_PORT=19090 ./im_bench
const std = @import("std");
const linux = std.os.linux;
const sws = @import("sws");
const AsyncServer = sws.AsyncServer;

const DEFAULT_PORT = 19090;
const CONNS = 50;
const REQS_PER_CONN = 100;
const DRAIN_IDLE_ROUNDS = 20;
const RESPONSE_MARKER = "{\"ok\":true}";

fn benchHandler(allocator: std.mem.Allocator, ctx: *sws.Context) anyerror!void {
    _ = allocator;
    try ctx.rawJson(200, "{\"ok\":true}");
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn countResponses(data: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, data[pos..], RESPONSE_MARKER)) |idx| {
        count += 1;
        pos += idx + RESPONSE_MARKER.len;
    }
    return count;
}

fn readPortEnv(default_port: u16) u16 {
    const raw = std.c.getenv("SWS_BENCH_PORT") orelse return default_port;
    // 修改原因：benchmark 跟随自测脚本端口配置，避免旧进程占用固定 19090 阻塞验证。
    return std.fmt.parseInt(u16, std.mem.span(raw), 10) catch default_port;
}

fn drainAvailable(fd: i32, buf: []u8) usize {
    var recv: usize = 0;
    while (true) {
        const raw = linux.recvfrom(fd, buf.ptr, buf.len, linux.MSG.DONTWAIT, null, null);
        const n_signed: isize = @bitCast(raw);
        if (n_signed <= 0) break;
        recv += countResponses(buf[0..@intCast(n_signed)]);
    }
    return recv;
}

fn drainUntil(fds: []const i32, buf: []u8, recv: *usize, target: usize, max_idle_rounds: usize) void {
    var idle_rounds: usize = 0;
    while (recv.* < target and idle_rounds < max_idle_rounds) {
        var progressed = false;
        for (fds) |dfd| {
            if (dfd == 0) continue;
            const n = drainAvailable(dfd, buf);
            if (n != 0) progressed = true;
            recv.* += n;
        }
        if (progressed) {
            idle_rounds = 0;
        } else {
            idle_rounds += 1;
            _ = linux.nanosleep(&linux.timespec{ .sec = 0, .nsec = 10_000_000 }, null);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const port = readPortEnv(DEFAULT_PORT);
    const addr = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port});
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
    var connected: usize = 0;
    for (&fds) |*fd| {
        const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (raw < 0) continue;
        const fd_val: i32 = @intCast(raw);
        const sa = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(@as(u16, port)),
            .addr = 0x0100007F,
            .zero = [_]u8{0} ** 8,
        };
        if (linux.connect(fd_val, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)) == 0) {
            fd.* = fd_val;
            connected += 1;
        } else {
            _ = linux.close(fd_val);
        }
    }

    const t_conn = nowMs();

    // send requests
    var buf: [65536]u8 = undefined;
    const req = "GET /bench HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
    var sent: usize = 0;
    var recv: usize = 0;

    const t_send0 = nowMs();
    var round: usize = 0;
    while (round < REQS_PER_CONN) : (round += 1) {
        for (&fds) |fd| {
            if (fd == 0) continue;
            const raw_written = linux.write(fd, req, req.len);
            const written: isize = @bitCast(raw_written);
            if (written == @as(isize, @intCast(req.len))) {
                sent += 1;
            }
        }
        // 修改原因：当前 server 不支持在同一连接中无限 HTTP pipelining，需收齐本轮响应后再发下一轮。
        drainUntil(fds[0..], buf[0..], &recv, sent, DRAIN_IDLE_ROUNDS);
    }
    // final drain
    // 修改原因：keep-alive 连接不会主动 EOF，阻塞 read 会让 benchmark 在收尾阶段卡住。
    drainUntil(fds[0..], buf[0..], &recv, sent, DRAIN_IDLE_ROUNDS);
    for (&fds) |dfd| {
        if (dfd == 0) continue;
        _ = linux.close(dfd);
    }

    const t_end = nowMs();
    server.stop();
    server_thread.join();

    const conn_ms = t_conn - t0;
    const send_ms: i64 = @max(t_end - t_send0, 1);
    const per_sec = @divTrunc(@as(i64, @intCast(sent)) * 1000, send_ms);

    std.debug.print("\n", .{});
    std.debug.print("  connections: {d} ({d} ms)\n", .{ connected, conn_ms });
    std.debug.print("  sent:        {d} req in {d} ms\n", .{ sent, send_ms });
    std.debug.print("  recv:        {d} resp\n", .{recv});
    std.debug.print("  throughput:  {d} req/s\n", .{per_sec});
    std.debug.print("\n", .{});
}
