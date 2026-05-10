const std = @import("std");

pub const DNS_PORT: u16 = 53;
pub const MAX_PACKET_SIZE: u16 = 512;

pub const RecordType = enum(u16) {
    A = 1,
    CNAME = 5,
    AAAA = 28,
    _,
};

pub const Rcode = enum(u4) {
    NOERROR = 0,
    FORMERR = 1,
    SERVFAIL = 2,
    NXDOMAIN = 3,
    NOTIMP = 4,
    REFUSED = 5,
    _,
};

pub const AddrList = struct {
    addrs: [MAX_ADDRS]u32,
    len: u8,
    pub const MAX_ADDRS = 8;
};

pub const ParsedResponse = struct {
    rcode: Rcode,
    ttl: u32,
    addrs: AddrList,
};

pub const QueryPacket = struct {
    buf: [MAX_PACKET_SIZE]u8,
    len: usize,

    pub fn bytes(self: *const QueryPacket) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn buildQuery(hostname: []const u8, txid: u16) !QueryPacket {
    var buf: [MAX_PACKET_SIZE]u8 = [_]u8{0} ** MAX_PACKET_SIZE;
    var off: usize = 0;

    std.mem.writeInt(u16, buf[off..][0..2], txid, .big);
    off += 2;
    buf[off] = 0x01;
    off += 1;
    buf[off] = 0x00;
    off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;

    off += try encodeName(hostname, buf[off..]);

    std.mem.writeInt(u16, buf[off..][0..2], 1, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big);
    off += 2;

    // 修改原因：DNS UDP 请求只能发送实际写入的报文长度，不能把 512 字节缓冲区整体发出去。
    return .{ .buf = buf, .len = off };
}

fn encodeName(name: []const u8, out: []u8) !usize {
    if (name.len == 0) {
        out[0] = 0;
        return 1;
    }
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len > 63) return error.LabelTooLong;
        if (label.len == 0) return error.EmptyLabel;
        // 修改原因：DNS 名称线格式最长 255 字节，超长 hostname 必须返回错误，不能继续写固定缓冲区导致越界。
        if (off + 1 + label.len + 1 > 255) return error.NameTooLong;
        if (off + 1 + label.len > out.len) return error.NameTooLong;
        out[off] = @intCast(label.len);
        off += 1;
        @memcpy(out[off..][0..label.len], label);
        off += label.len;
    }
    if (off + 1 > out.len) return error.NameTooLong;
    out[off] = 0;
    off += 1;
    return off;
}

pub fn parseResponse(packet: []const u8) ParsedResponse {
    var resp = ParsedResponse{
        .rcode = .NOERROR,
        .ttl = 60,
        .addrs = .{ .addrs = [_]u32{0} ** AddrList.MAX_ADDRS, .len = 0 },
    };

    if (packet.len < 12) {
        resp.rcode = .SERVFAIL;
        return resp;
    }

    const flags1 = packet[2];
    const qr = (flags1 >> 7) & 1;
    if (qr != 1) {
        resp.rcode = .SERVFAIL;
        return resp;
    }

    const flags2 = packet[3];
    resp.rcode = @enumFromInt(flags2 & 0x0F);
    if (resp.rcode != .NOERROR) return resp;

    const ancount = std.mem.readInt(u16, packet[6..8], .big);
    // 修改原因：authority/additional section 中的 A 记录不是当前查询名的答案，不能当解析结果返回。
    const total = ancount;

    var off: usize = 12;

    var qi: u16 = 0;
    _ = &qi;
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        off = skipName(packet, off);
        if (off + 4 > packet.len) {
            resp.rcode = .SERVFAIL;
            return resp;
        }
        off += 4;
    }

    var min_ttl: u32 = std.math.maxInt(u32);
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        off = skipName(packet, off);
        if (off + 10 > packet.len) {
            // 修改原因：畸形 DNS name 可能让 skipName 直接返回 packet.len；
            // 必须在跳过 name 后再检查 RR 头长度，避免后续 readInt 越界 panic。
            break;
        }
        const rtype = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2;
        _ = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2; // class
        const ttl = std.mem.readInt(u32, packet[off..][0..4], .big);
        off += 4;
        const rdlen = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2;

        if (off + rdlen > packet.len) break;

        if (rtype == 1 and rdlen == 4) {
            if (resp.addrs.len < AddrList.MAX_ADDRS) {
                const ip: u32 = (@as(u32, packet[off]) << 24) |
                    (@as(u32, packet[off + 1]) << 16) |
                    (@as(u32, packet[off + 2]) << 8) |
                    @as(u32, packet[off + 3]);
                // 修改原因：A 记录会被后续 TCP connect 直接写入 sockaddr，需保存为网络字节序布局。
                resp.addrs.addrs[resp.addrs.len] = std.mem.nativeToBig(u32, ip);
                resp.addrs.len += 1;
            }
            if (ttl < min_ttl) min_ttl = ttl;
        }
        off += rdlen;
    }

    if (min_ttl != std.math.maxInt(u32)) resp.ttl = min_ttl;
    return resp;
}

fn skipName(packet: []const u8, start: usize) usize {
    var off = start;
    while (off < packet.len) {
        const len = packet[off];
        if (len == 0) return off + 1;
        if (len & 0xC0 == 0xC0) return off + 2;
        off += @as(usize, len) + 1;
    }
    return packet.len;
}

pub fn parseTxid(packet: []const u8) u16 {
    if (packet.len < 2) return 0;
    return std.mem.readInt(u16, packet[0..2], .big);
}

fn appendTestRootARecord(buf: []u8, off: *usize, ip: [4]u8) void {
    buf[off.*] = 0;
    off.* += 1;
    std.mem.writeInt(u16, buf[off.*..][0..2], 1, .big);
    off.* += 2;
    std.mem.writeInt(u16, buf[off.*..][0..2], 1, .big);
    off.* += 2;
    std.mem.writeInt(u32, buf[off.*..][0..4], 60, .big);
    off.* += 4;
    std.mem.writeInt(u16, buf[off.*..][0..2], 4, .big);
    off.* += 2;
    @memcpy(buf[off.*..][0..4], &ip);
    off.* += 4;
}

test "buildQuery reports actual DNS message length" {
    const query = try buildQuery("example.com", 0x1234);

    try std.testing.expectEqual(@as(usize, 29), query.len);
    try std.testing.expectEqual(query.len, query.bytes().len);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, query.buf[0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, query.buf[query.len - 4 ..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, query.buf[query.len - 2 ..][0..2], .big));
}

test "buildQuery rejects DNS names longer than wire limit" {
    var name_buf: [259]u8 = undefined;
    var pos: usize = 0;
    for (0..130) |i| {
        if (i != 0) {
            name_buf[pos] = '.';
            pos += 1;
        }
        name_buf[pos] = 'a';
        pos += 1;
    }

    try std.testing.expectError(error.NameTooLong, buildQuery(name_buf[0..pos], 0x1234));
}

test "parseResponse tolerates malformed answer name" {
    var pkt = [_]u8{0} ** 24;
    pkt[2] = 0x80; // QR response
    pkt[7] = 1; // ANCOUNT = 1
    pkt[12] = 20; // label claims more bytes than the packet contains

    const parsed = parseResponse(&pkt);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse ignores additional A records" {
    var pkt = [_]u8{0} ** 42;
    pkt[2] = 0x80; // QR response
    pkt[7] = 1; // ANCOUNT = 1
    pkt[11] = 1; // ARCOUNT = 1

    var off: usize = 12;
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });
    appendTestRootARecord(&pkt, &off, .{ 5, 6, 7, 8 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(@as(u8, 1), parsed.addrs.len);
    try std.testing.expectEqual(std.mem.nativeToBig(u32, 0x01020304), parsed.addrs.addrs[0]);
}

test "parseResponse rejects truncated question" {
    var pkt = [_]u8{0} ** 16;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[12] = 20; // malformed question name

    const parsed = parseResponse(&pkt);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
}
