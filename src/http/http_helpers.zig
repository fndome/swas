const std = @import("std");
const MAX_PATH_LENGTH = @import("../constants.zig").MAX_PATH_LENGTH;

pub fn getMethodFromRequest(buf: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, buf, "\r\n") orelse std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    const line = buf[0..end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    return line[0..first_space];
}

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

/// 从 HTTP 请求行中提取 URI 的完整路径（含 query string）
pub fn getFullUri(buf: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, buf, "\r\n") orelse std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    const line = buf[0..end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    var rest = line[first_space + 1 ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..second_space];
}

/// 从 query string 中提取指定参数的值
pub fn extractQueryParam(uri: []const u8, name: []const u8) ?[]const u8 {
    const q_pos = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
    const qs = uri[q_pos + 1 ..];
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq_pos];
        if (std.mem.eql(u8, key, name)) {
            const val = pair[eq_pos + 1 ..];
            return val;
        }
    }
    return null;
}

/// 从 HTTP 请求头部提取指定 header 的值（大小写不敏感）
pub fn extractHeader(data: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, name)) {
            if (line.len <= name.len) return null;
            const after = line[name.len..];
            if (after.len > 0 and after[0] == ':') {
                return std.mem.trim(u8, after[1..], " \t\r\n");
            }
        }
    }
    return null;
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
    const ip = (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        (@as(u32, octets[3]));
    // 修改原因：linux.sockaddr.in.addr 需要内存中为网络字节序，直接返回文本序数值会把 127.0.0.1 绑定成 1.0.0.127。
    return std.mem.nativeToBig(u32, ip);
}

pub fn logErr(comptime format: []const u8, args: anytype) void {
    std.debug.print("[ERROR] " ++ format ++ "\n", args);
}
