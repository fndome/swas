const std = @import("std");
const MAX_PATH_LENGTH = @import("../constants.zig").MAX_PATH_LENGTH;

pub fn getPathFromRequest(buf: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, buf, "\r\n") orelse std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    const line = buf[0..end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    var rest = line[first_space + 1 ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const raw = rest[0..second_space];
    if (raw.len == 0 or raw.len > MAX_PATH_LENGTH) return null;
    const q_pos = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..q_pos];
}

pub fn isKeepAliveConnection(buf: []const u8) bool {
    const http11 = std.mem.indexOf(u8, buf, "HTTP/1.1") != null;
    var lines = std.mem.splitSequence(u8, buf, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Connection:")) {
            const value = std.mem.trim(u8, line["Connection:".len..], " \t");
            if (std.ascii.indexOfIgnoreCase(value, "close") != null) return false;
            if (std.ascii.indexOfIgnoreCase(value, "keep-alive") != null) return true;
        }
    }
    return http11;
}

pub fn parseIpv4(ip_str: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, ip_str, '.');
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidIp;
    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        (@as(u32, octets[3]));
}

pub fn logErr(comptime format: []const u8, args: anytype) void {
    std.debug.print("[ERROR] " ++ format ++ "\n", args);
}
