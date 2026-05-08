const std = @import("std");
const sws = @import("sws");

/// ── im-ws 一致性哈希环初始化 ──────────────────────────────
///
/// 每个 im-ws Pod 启动时调用 initRing(local_id)。
/// local_id 从 POD_NAME 环境变量解析: "im-ws-2" → 2。
///
/// 环用于:
///   1. 建连校验: im-router 做了 hash%N 第一次路由，
///      Pod 内用环做二次校验，防 ring 漂移。
///   2. 消息路由: hash(to_uid) → 目标 Pod ordinal，
///      判断目标在本地还是远程。
///   3. 扩容减震: 虚节点环迁移率 ~25%，vs 取模 75%。

pub var local_id: u8 = 0;

pub fn loadLocalId() void {
    local_id = parseLocalId();
}

fn parseLocalId() u8 {
    const pod_name = std.os.getenv("POD_NAME") orelse "im-ws-0";
    const last_dash = std.mem.lastIndexOfScalar(u8, pod_name, '-') orelse
        @panic("invalid POD_NAME format");
    const ordinal_str = pod_name[last_dash + 1 ..];
    return std.fmt.parseInt(u8, ordinal_str, 10) catch
        @panic("invalid POD_NAME ordinal");
}

pub fn initRing(alloc: std.mem.Allocator, node_count: u8) !sws.HashRing {
    var ring = sws.HashRing.init(alloc, local_id);
    var i: u8 = 0;
    while (i < node_count) : (i += 1) {
        try ring.addNode(i);
    }
    return ring;
}

// ── 建连校验 ────────────────────────────────────────────────
// handler 收到 WS upgrade 后:
//   const uid = parseJwt(token);
//   if (!isLocal(ring, uid)) {
//       server.sendWsFrame(conn_id, .text,
//           \\{"type":"redirect","url":"ws://..."}
//       );
//       return;
//   }
//   sessions.add(conn_id, uid);

pub fn isLocal(ring: *const sws.HashRing, user_id: u64) bool {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, user_id, .little);
    const key_hash: u32 = @truncate(sws.hash64(&buf));
    return ring.routeIsLocal(key_hash);
}

// ── 消息路由 ────────────────────────────────────────────────
// 发送消息时判断目标在哪个 Pod:
//   const target = routeToNode(ring, to_uid);
//   if (target == local_id) {
//       sessions.push(to_uid, frame);
//   } else {
//       forwardToPeer(target, frame);
//   }

pub fn routeToNode(ring: *const sws.HashRing, user_id: u64) u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, user_id, .little);
    const key_hash: u32 = @truncate(sws.hash64(&buf));
    return ring.route(key_hash);
}
