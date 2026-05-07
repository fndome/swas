const std = @import("std");
const TcpOutboundRing = @import("../outbound/tcp_outbound_ring.zig").TcpOutboundRing;
const TcpConn = @import("../outbound/tcp_outbound_ring.zig").TcpConn;

/// ── MySQL 协议薄层 on TcpOutboundRing ────────────────────
///
/// 不依赖 RingB(HTTP) / RingC(NATS)。
/// 独立 tcp_outbound_ring + connect/auth/query → attachStream → Worker 解析。
///
/// 同一 TcpOutboundRing 可复用给 Redis、PostgreSQL、MongoDB 等任何 TCP 协议。
///
/// 用法:
///   var ring = try TcpOutboundRing.init(alloc, 256);
///   defer ring.deinit();
///   const conn = try mysqlConnect(&ring, "127.0.0.1", 3306);
///   try mysqlAuth(&ring, conn, "root", "", "im");
///   try mysqlQuery(&ring, conn, "SELECT * FROM t_msg");
///   ring.attachStream(conn, stream);
///   // 此后 ring.tick() → stream.feed → Worker

const HEADER_SIZE = 4;
const MAX_PAYLOAD = 0xFFFFFF; // 16MB - 1

/// 阻塞式 MySQL 连接 (内部 tick 直到 connect 或超时)
pub fn mysqlConnect(ring: *TcpOutboundRing, host: []const u8, port: u16) !*TcpConn {
    const conn = try ring.connect(host, port);
    // tick until connected
    var deadline: usize = 1000;
    while (conn.state == .connecting and deadline > 0) : (deadline -= 1) {
        ring.tick();
    }
    if (conn.state == .connecting) return error.ConnectTimeout;
    return conn;
}

/// 发送 MySQL 认证包。调用前需先 read greeting (由 ring.tick 驱动)
pub fn mysqlAuth(ring: *TcpOutboundRing, conn: *TcpConn, user: []const u8, password: []const u8, database: []const u8) !void {
    _ = password;

    // Build auth response (simplified: no actual auth challenge parsing)
    // Production code would: 1) read greeting from ring, 2) parse auth_plugin_data, 3) build response
    var buf: [128]u8 = undefined;
    var pos: usize = 0;

    // Placeholder length (filled below)
    pos += 4;

    buf[pos] = 1; pos += 1; // seq=1 (handshake response)

    // Client capabilities: PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH | CONNECT_WITH_DB
    const caps: u32 = 0xFA85;
    std.mem.writeInt(u32, buf[pos..][0..4], caps, .little); pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], MAX_PAYLOAD, .little); pos += 4; // max_packet_size
    buf[pos] = 33; pos += 1; // charset utf8mb4
    @memset(buf[pos..][0..23], 0); pos += 23; // reserved

    // User
    @memcpy(buf[pos..][0..user.len], user); pos += user.len;
    buf[pos] = 0; pos += 1;

    // Auth response length + data (zeros for empty password)
    buf[pos] = 0; pos += 1; // auth_response_len = 0 (empty password)

    // Database
    if (database.len > 0) {
        @memcpy(buf[pos..][0..database.len], database);
        pos += database.len;
        buf[pos] = 0; pos += 1;
    }

    // Fill header
    const payload_len = pos - 4;
    std.mem.writeInt(u24, buf[0..3], @intCast(payload_len), .little);

    try ring.write(conn, buf[0..pos]);
    // ring.tick() will process the write + subsequent auth OK/ERR read
}

/// 发送 MySQL COM_QUERY。
pub fn mysqlQuery(ring: *TcpOutboundRing, conn: *TcpConn, sql: []const u8) !void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u24, header[0..3], @intCast(1 + sql.len), .little);
    header[3] = 0; // seq=0
    header[4] = 0x03; // COM_QUERY

    try ring.write(conn, header[0..5]);
    if (sql.len > 0) try ring.write(conn, sql);
}
