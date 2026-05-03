const std = @import("std");

const websocket_magic = "258EAFA5-E914-47DA-95CA-5AB9DC11B85B";

pub fn isUpgradeRequest(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\r\n\r\n") == null) return false;

    var has_upgrade = false;
    var has_ws_key = false;
    var has_ws_version = false;
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "Upgrade:")) {
            const value = std.mem.trim(u8, line[7..], " \t");
            if (std.ascii.eqlIgnoreCase(value, "websocket")) {
                has_upgrade = true;
            }
        }
        if (std.ascii.startsWithIgnoreCase(line, "Sec-WebSocket-Key:")) {
            has_ws_key = true;
        }
        if (std.ascii.startsWithIgnoreCase(line, "Sec-WebSocket-Version:")) {
            const value = std.mem.trim(u8, line[22..], " \t\r\n");
            if (std.mem.eql(u8, value, "13")) {
                has_ws_version = true;
            }
        }
    }
    return has_upgrade and has_ws_key and has_ws_version;
}

pub fn extractWsKey(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Sec-WebSocket-Key:")) {
            const key_start = line[18..];
            const trimmed = std.mem.trim(u8, key_start, " \t\r\n");
            return trimmed;
        }
    }
    return null;
}

pub fn computeAcceptKey(key: []const u8, buf: *[29]u8) !void {
    const Sha1 = std.crypto.hash.Sha1;
    const max_key_len: usize = 128 - websocket_magic.len;
    if (key.len > max_key_len) return error.KeyTooLong;

    var concat: [128]u8 = undefined;
    @memcpy(concat[0..key.len], key);
    @memcpy(concat[key.len..][0..websocket_magic.len], websocket_magic);
    const input = concat[0 .. key.len + websocket_magic.len];

    var hash: [20]u8 = undefined;
    Sha1.hash(input, &hash, .{});

    _ = std.base64.standard.Encoder.encode(buf[0..28], &hash);
    buf[28] = 0;
}

pub fn buildUpgradeResponse(buf: []u8, accept_key: []const u8) !usize {
    const written = try std.fmt.bufPrint(
        buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept_key},
    );
    return written.len;
}
