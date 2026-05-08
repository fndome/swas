const std = @import("std");
const Allocator = std.mem.Allocator;

/// ── 一致性哈希环 (虚节点) ─────────────────────────────────
///
/// 基于 sws 的 IM 应用在 K8s 中部署时，用此模块做用户→Pod 路由。
/// im-router (Go) 和 im-ws (Zig) 各持一份同算法实现。
/// 两层用同一套 FNV-1a + 150 虚节点 + 二分查找，扩容零漂移。
///
/// 每个物理节点占 150 个虚节点，分散在环上各处。
/// 扩容时只有 ~39% 的 key 需要迁移（vs 取模 75%）。
///
/// 用法:
///   var ring = HashRing.init(alloc, local_id);
///   try ring.addNode(0);
///   try ring.addNode(1);
///   const target = ring.route(user_id);  // → 目标节点 ID
///   ring.routeIsLocal(user_id);          // → 是否路由到本机
///
/// 扩容:
///   try ring.addNode(3);  // 3→4, 约 25% key 迁移
///
/// 缩容:
///   ring.removeNode(3);   // 4→3, 被删节点的 key 顺移给邻居
pub const HashRing = struct {
    const Self = @This();
    const VNODES_PER_NODE: u16 = 150;

    allocator: Allocator,
    /// 本机节点 ID (从 POD_NAME 解析，如 im-ws-2 → 2)
    local_id: u8,
    /// 虚节点数组，按 hash 值排序
    vnodes: std.ArrayList(VNode),
    /// 当前有哪些物理节点 (用于重建)
    nodes: std.ArrayList(u8),

    const VNode = struct {
        /// hash32("{node_id}-{vi}")
        hash: u32,
        /// 归属的物理节点 ID
        node_id: u8,

        fn lessThan(_: void, a: VNode, b: VNode) bool {
            return a.hash < b.hash;
        }
    };

    pub fn init(allocator: Allocator, local_id: u8) Self {
        return .{
            .allocator = allocator,
            .local_id = local_id,
            .vnodes = std.ArrayList(VNode).init(allocator),
            .nodes = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.vnodes.deinit();
        self.nodes.deinit();
    }

    /// 添加物理节点到环。
    /// 每个节点生成 VNODES_PER_NODE 个虚节点，分散插入环。
    pub fn addNode(self: *Self, node_id: u8) !void {
        var vi: u16 = 0;
        while (vi < VNODES_PER_NODE) : (vi += 1) {
            const seed = hashVnodeSeed(node_id, vi);
            const h = hash32(seed[0..seed.len]);
            try self.vnodes.append(.{ .hash = h, .node_id = node_id });
        }
        try self.nodes.append(node_id);
        sortRing(self.vnodes.items);
    }

    /// 从环中移除物理节点。
    /// 移除该节点所有虚节点，剩余 key 由顺时针邻居接管。
    pub fn removeNode(self: *Self, node_id: u8) void {
        var i: usize = 0;
        while (i < self.vnodes.items.len) {
            if (self.vnodes.items[i].node_id == node_id) {
                _ = self.vnodes.swapRemove(i);
            } else {
                i += 1;
            }
        }
        for (self.nodes.items, 0..) |n, j| {
            if (n == node_id) {
                _ = self.nodes.swapRemove(j);
                break;
            }
        }
        sortRing(self.vnodes.items);
    }

    /// 路由: 给定 key (通常 hash64(user_id) 的低 32 位)，返回归属的物理节点 ID。
    /// 环上二分查找 → 顺时针最近虚节点 → 归属的物理节点。
    pub fn route(self: *const Self, key_hash: u32) u8 {
        if (self.vnodes.items.len == 0) return 0;

        const pos = binarySearch(self.vnodes.items, key_hash);
        return self.vnodes.items[pos].node_id;
    }

    /// 路由到本机？
    pub fn routeIsLocal(self: *const Self, key_hash: u32) bool {
        return self.route(key_hash) == self.local_id;
    }

    /// 返回 key 应该归属的节点 ID 是否与本机不同。
    /// 用于建连时二次校验——im-router 用取模做了第一次路由，
    /// 这里用环做第二次校验，防止 ring 变化后的极少数漂移。
    pub fn routeIsRemote(self: *const Self, key_hash: u32) bool {
        return !self.routeIsLocal(key_hash);
    }

    /// 当前环上的节点数
    pub fn nodeCount(self: *const Self) usize {
        return self.nodes.items.len;
    }

    /// 当前环上的虚节点总数
    pub fn vnodeCount(self: *const Self) usize {
        return self.vnodes.items.len;
    }
};

/// 二分查找: 找 key_hash 在排序环上的顺时针最近位置。
/// 返回 vnodes 中的索引。
fn binarySearch(vnodes: []const HashRing.VNode, key_hash: u32) usize {
    if (vnodes.len == 0) return 0;
    if (key_hash > vnodes[vnodes.len - 1].hash) return 0;

    var lo: usize = 0;
    var hi: usize = vnodes.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (vnodes[mid].hash < key_hash) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// 排序环 (插入后或删除后调用)
fn sortRing(vnodes: []HashRing.VNode) void {
    std.sort.insertion(HashRing.VNode, vnodes, {}, HashRing.VNode.lessThan);
}

fn hashVnodeSeed(node_id: u8, vi: u16) []u8 {
    const s = std.fmt.bufPrint(&seed_buf, "{d}-{d}", .{ node_id, vi }) catch unreachable;
    return seed_buf[0..s.len];
}

var seed_buf: [64]u8 = undefined;

/// FNV-1a 32-bit hash
pub fn hash32(data: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (data) |c| {
        h ^= @as(u32, c);
        h *%= 0x01000193;
    }
    return h;
}

/// FNV-1a 64-bit hash (用于 user_id → 低 32 位 → 环路由)
pub fn hash64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |c| {
        h ^= @as(u64, c);
        h *%= 0x100000001b3;
    }
    return h;
}

// ── 测试 ──────────────────────────────────────────────────────

test "ring basic: add nodes and route" {
    const alloc = std.testing.allocator;
    var ring = HashRing.init(alloc, 1);
    defer ring.deinit();

    try ring.addNode(0);
    try ring.addNode(1);
    try ring.addNode(2);

    try std.testing.expect(ring.nodeCount() == 3);
    try std.testing.expect(ring.vnodeCount() == 3 * HashRing.VNODES_PER_NODE);
}

test "ring: route consistency — same key → same node" {
    const alloc = std.testing.allocator;
    var ring = HashRing.init(alloc, 0);
    defer ring.deinit();

    try ring.addNode(0);
    try ring.addNode(1);
    try ring.addNode(2);

    const key: u32 = 0x12345678;
    const node1 = ring.route(key);
    const node2 = ring.route(key);
    try std.testing.expectEqual(node1, node2);
}

test "ring: route is deterministic across rings with same nodes" {
    const alloc = std.testing.allocator;

    var ring_a = HashRing.init(alloc, 0);
    defer ring_a.deinit();
    try ring_a.addNode(0);
    try ring_a.addNode(1);
    try ring_a.addNode(2);

    var ring_b = HashRing.init(alloc, 1);
    defer ring_b.deinit();
    try ring_b.addNode(0);
    try ring_b.addNode(1);
    try ring_b.addNode(2);

    // 同一 key 在不同 Pod 的环上应路由到同一物理节点
    const key: u32 = 0xDEADBEEF;
    try std.testing.expectEqual(ring_a.route(key), ring_b.route(key));
}

test "ring: scale up 3→4, verify ~25% migration" {
    const alloc = std.testing.allocator;

    var ring3 = HashRing.init(alloc, 0);
    defer ring3.deinit();
    try ring3.addNode(0);
    try ring3.addNode(1);
    try ring3.addNode(2);

    var ring4 = HashRing.init(alloc, 0);
    defer ring4.deinit();
    try ring4.addNode(0);
    try ring4.addNode(1);
    try ring4.addNode(2);
    try ring4.addNode(3);

    // 采样 10000 个 key，统计有多少 key 的归属变了
    var changed: usize = 0;
    const samples: usize = 10000;
    var seed: u32 = 1;
    for (0..samples) |_| {
        seed = hash32(std.mem.asBytes(&seed));
        if (ring3.route(seed) != ring4.route(seed)) {
            changed += 1;
        }
    }

    const pct = @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(samples)) * 100.0;
    // 虚节点一致性哈希，迁移率应在 20-30% 之间
    try std.testing.expect(pct >= 15.0);
    try std.testing.expect(pct <= 35.0);
}

test "ring: remove node returns valid route" {
    const alloc = std.testing.allocator;
    var ring = HashRing.init(alloc, 0);
    defer ring.deinit();

    try ring.addNode(0);
    try ring.addNode(1);
    try ring.addNode(2);

    ring.removeNode(1);
    try std.testing.expect(ring.nodeCount() == 2);
    try std.testing.expect(ring.vnodeCount() == 2 * HashRing.VNODES_PER_NODE);

    // 所有 key 仍应路由到有效节点 (0 或 2)
    const key: u32 = 0xCAFEBABE;
    const node = ring.route(key);
    try std.testing.expect(node == 0 or node == 2);
}

test "ring: empty ring returns 0" {
    const alloc = std.testing.allocator;
    var ring = HashRing.init(alloc, 0);
    defer ring.deinit();

    try std.testing.expectEqual(@as(u8, 0), ring.route(0xDEAD));
}

test "ring: local/remote check" {
    const alloc = std.testing.allocator;
    var ring = HashRing.init(alloc, 0);
    defer ring.deinit();

    try ring.addNode(0);
    try ring.addNode(1);

    var local_count: usize = 0;
    var remote_count: usize = 0;
    var seed: u32 = 1;
    for (0..1000) |_| {
        seed = hash32(std.mem.asBytes(&seed));
        if (ring.routeIsLocal(seed)) {
            local_count += 1;
        } else {
            remote_count += 1;
        }
    }

    // 两个节点，大约 50% 本地
    const local_pct = @as(f64, @floatFromInt(local_count)) / 10.0;
    try std.testing.expect(local_pct >= 35.0);
    try std.testing.expect(local_pct <= 65.0);
}
