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

pub fn buildQuery(hostname: []const u8, txid: u16) ![MAX_PACKET_SIZE]u8 {
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

    off += encodeName(hostname, buf[off..]);

    std.mem.writeInt(u16, buf[off..][0..2], 1, .big);
    off += 2;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big);
    off += 2;

    return buf;
}

fn encodeName(name: []const u8, out: []u8) usize {
    if (name.len == 0) {
        out[0] = 0;
        return 1;
    }
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len > 63 or label.len == 0) continue;
        out[off] = @intCast(label.len);
        off += 1;
        @memcpy(out[off..][0..label.len], label);
        off += label.len;
    }
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
    const nscount = std.mem.readInt(u16, packet[8..10], .big);
    const arcount = std.mem.readInt(u16, packet[10..12], .big);
    const total = @as(usize, ancount) + @as(usize, nscount) + @as(usize, arcount);

    var off: usize = 12;

    var qi: u16 = 0;
    _ = &qi;
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        off = skipName(packet, off);
        off += 4;
    }

    var min_ttl: u32 = std.math.maxInt(u32);
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        if (off + 10 > packet.len) break;
        off = skipName(packet, off);
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
