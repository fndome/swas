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
    // 修改原因：DNS 绝对域名允许末尾点，例如 example.com.；末尾点只表示 root，不能当成空 label 报错。
    const wire_name = if (name[name.len - 1] == '.') name[0 .. name.len - 1] else name;
    if (wire_name.len == 0) {
        out[0] = 0;
        return 1;
    }
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, wire_name, '.');
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
    // 修改原因：resolver 只发标准 QUERY，非 0 opcode 的响应不能按普通 hostname 查询结果解析。
    if (((flags1 >> 3) & 0x0F) != 0) {
        resp.rcode = .SERVFAIL;
        return resp;
    }
    // 修改原因：TC 表示 UDP 响应已截断，继续使用其中的 A 记录会把不完整答案当成完整解析结果。
    if ((flags1 & 0x02) != 0) {
        resp.rcode = .SERVFAIL;
        return resp;
    }

    const flags2 = packet[3];
    resp.rcode = @enumFromInt(flags2 & 0x0F);
    if (resp.rcode != .NOERROR) return resp;

    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    // 修改原因：resolver 只会发送单 question 查询，问题数异常的响应不能可靠对应当前 hostname。
    if (qdcount != 1) {
        resp.rcode = .SERVFAIL;
        return resp;
    }

    const ancount = std.mem.readInt(u16, packet[6..8], .big);
    // 修改原因：authority/additional section 中的 A 记录不是当前查询名的答案，不能当解析结果返回。
    const total = ancount;

    var off: usize = 12;

    var qi: u16 = 0;
    _ = &qi;
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        off = skipName(packet, off) orelse {
            resp.rcode = .SERVFAIL;
            return resp;
        };
        if (off + 4 > packet.len) {
            resp.rcode = .SERVFAIL;
            return resp;
        }
        const qtype = std.mem.readInt(u16, packet[off..][0..2], .big);
        const qclass = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big);
        // 修改原因：resolver 只查询 A/IN，响应 question 回显不一致时不能信任后续 answer。
        if (qtype != 1 or qclass != 1) {
            resp.rcode = .SERVFAIL;
            return resp;
        }
        off += 4;
    }

    var min_ttl: u32 = std.math.maxInt(u32);
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        off = skipName(packet, off) orelse break;
        if (off + 10 > packet.len) {
            // 修改原因：即使 name 合法，后续 RR 头也可能被截断，必须在 readInt 前检查长度。
            break;
        }
        const rtype = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2;
        const rclass = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2; // class
        const ttl = std.mem.readInt(u32, packet[off..][0..4], .big);
        off += 4;
        const rdlen = std.mem.readInt(u16, packet[off..][0..2], .big);
        off += 2;

        if (off + rdlen > packet.len) break;

        // 修改原因：只有 IN class 的 A 记录才是 IPv4 地址答案，不能把 CHAOS/HS 等其它 class 的 A 记录写入连接地址。
        if (rtype == 1 and rclass == 1 and rdlen == 4) {
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

fn skipName(packet: []const u8, start: usize) ?usize {
    var off = start;
    while (off < packet.len) {
        const len = packet[off];
        if (len == 0) return off + 1;
        if (len & 0xC0 == 0xC0) {
            // 修改原因：压缩指针必须完整占 2 字节，缺少第二字节时不能继续解析后续字段。
            if (off + 2 > packet.len) return null;
            return off + 2;
        }
        // 修改原因：DNS 普通 label 最高两位必须为 00；保留格式和超长 label 都是 malformed name。
        if ((len & 0xC0) != 0 or len > 63) return null;
        if (off + 1 + @as(usize, len) > packet.len) return null;
        off += @as(usize, len) + 1;
    }
    return null;
}

pub fn parseTxid(packet: []const u8) u16 {
    if (packet.len < 2) return 0;
    return std.mem.readInt(u16, packet[0..2], .big);
}

fn appendTestRootARecord(buf: []u8, off: *usize, ip: [4]u8) void {
    appendTestRootARecordWithClass(buf, off, ip, 1);
}

// 修改原因：DNS 响应测试样本必须带 resolver 实际发送的单 question，避免绕过 QDCOUNT 校验。
fn appendTestRootQuestion(buf: []u8, off: *usize) void {
    appendTestRootQuestionWithTypeClass(buf, off, 1, 1);
}

fn appendTestRootQuestionWithTypeClass(buf: []u8, off: *usize, qtype: u16, qclass: u16) void {
    buf[off.*] = 0;
    off.* += 1;
    std.mem.writeInt(u16, buf[off.*..][0..2], qtype, .big);
    off.* += 2;
    std.mem.writeInt(u16, buf[off.*..][0..2], qclass, .big);
    off.* += 2;
}

fn appendTestRootARecordWithClass(buf: []u8, off: *usize, ip: [4]u8, class: u16) void {
    buf[off.*] = 0;
    off.* += 1;
    std.mem.writeInt(u16, buf[off.*..][0..2], 1, .big);
    off.* += 2;
    std.mem.writeInt(u16, buf[off.*..][0..2], class, .big);
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

test "buildQuery accepts trailing root dot" {
    const relative = try buildQuery("example.com", 0x1234);
    const absolute = try buildQuery("example.com.", 0x1234);
    try std.testing.expectEqualSlices(u8, relative.bytes(), absolute.bytes());

    const root = try buildQuery(".", 0x1234);
    try std.testing.expectEqual(@as(usize, 17), root.len);
    try std.testing.expectEqual(@as(u8, 0), root.buf[12]);
}

test "parseResponse tolerates malformed answer name" {
    var pkt = [_]u8{0} ** 24;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1
    var off: usize = 12;
    appendTestRootQuestion(&pkt, &off);
    pkt[off] = 20; // label claims more bytes than the packet contains

    const parsed = parseResponse(&pkt);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse ignores additional A records" {
    var pkt = [_]u8{0} ** 47;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1
    pkt[11] = 1; // ARCOUNT = 1

    var off: usize = 12;
    appendTestRootQuestion(&pkt, &off);
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });
    appendTestRootARecord(&pkt, &off, .{ 5, 6, 7, 8 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(@as(u8, 1), parsed.addrs.len);
    try std.testing.expectEqual(std.mem.nativeToBig(u32, 0x01020304), parsed.addrs.addrs[0]);
}

test "parseResponse ignores non-IN A records" {
    var pkt = [_]u8{0} ** 32;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1

    var off: usize = 12;
    appendTestRootQuestion(&pkt, &off);
    appendTestRootARecordWithClass(&pkt, &off, .{ 9, 9, 9, 9 }, 3);

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse rejects truncated question" {
    var pkt = [_]u8{0} ** 16;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[12] = 20; // malformed question name

    const parsed = parseResponse(&pkt);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
}

test "parseResponse rejects reserved question label format" {
    var pkt = [_]u8{0} ** 17;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[12] = 0x40; // reserved label format, not a length or compression pointer

    const parsed = parseResponse(&pkt);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
}

test "parseResponse rejects unexpected question count" {
    var pkt = [_]u8{0} ** 28;
    pkt[2] = 0x80; // QR response
    pkt[7] = 1; // ANCOUNT = 1, but QDCOUNT stays 0

    var off: usize = 12;
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse rejects truncated response" {
    var pkt = [_]u8{0} ** 32;
    pkt[2] = 0x82; // QR response + TC truncated flag
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1

    var off: usize = 12;
    appendTestRootQuestion(&pkt, &off);
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse rejects non-query opcode response" {
    var pkt = [_]u8{0} ** 32;
    pkt[2] = 0x88; // QR response + opcode 1 instead of standard QUERY
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1

    var off: usize = 12;
    appendTestRootQuestion(&pkt, &off);
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}

test "parseResponse rejects mismatched question type" {
    var pkt = [_]u8{0} ** 32;
    pkt[2] = 0x80; // QR response
    pkt[5] = 1; // QDCOUNT = 1
    pkt[7] = 1; // ANCOUNT = 1

    var off: usize = 12;
    appendTestRootQuestionWithTypeClass(&pkt, &off, 28, 1);
    appendTestRootARecord(&pkt, &off, .{ 1, 2, 3, 4 });

    const parsed = parseResponse(pkt[0..off]);
    try std.testing.expectEqual(Rcode.SERVFAIL, parsed.rcode);
    try std.testing.expectEqual(@as(u8, 0), parsed.addrs.len);
}
