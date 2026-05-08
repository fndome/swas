# IM-WS K8s 部署指南

## 架构概览

```
                           K8s Cluster
  Client                    ┌─────────────────────────────────────────┐
  ── https://ws.example.com/ws?uid=123456&token=xxx ──┐              │
                            │                          ▼              │
                            │              ┌─────────────────────┐   │
                            │              │   im-router (Go)    │   │
                            │              │   hash(uid) % N     │   │
                            │              │   → redirect port   │   │
                            │              └────────┬────────────┘   │
                            │                       │                │
                            │     {"url":"ws://ws.example.com:30001/ws","node":0}
  ← redirect ───────────────┘                       │                │
                                                    │                │
  ── ws://ws.example.com:30001/ws ──────────────────┼──┐             │
                            │                       │  │             │
                            │              ┌────────▼──▼──────────┐ │
                            │              │   NodePort 30001     │ │
                            │              │   eBPF DNAT → PodIP  │ │
                            │              └────────┬────────────┘ │
                            │                       │               │
                            │              ┌────────▼──────────┐   │
                            │              │    im-ws-0         │   │
                            │              │   (sws/Zig)        │   │
                            │              │   1C / 2GB         │   │
                            │              │   StackPool 1M     │   │
                            │              └───┬──────┬────────┘   │
                            │                  │      │             │
                            │        ┌─────────┘      └───────┐    │
                            │        ▼                         ▼    │
                            │  ┌──────────┐            ┌──────────┐ │
                            │  │  NATS    │            │ im-ws-1  │ │
                            │  │ JetStream│            │ im-ws-2  │ │
                            │  │ 离线消息  │            │   ...    │ │
                            │  └──────────┘            └──────────┘ │
                            └─────────────────────────────────────────┘
```

## 负载均衡策略

### 不用 K8s Service LoadBalancer

K8s Service 的 iptables/IPVS 模式会把同一用户的消息**随机分发**到不同 Pod，导致：

- 每个 Pod 都要维护一份 NATS consumer
- 消息量 ×N 倍放大
- 在线状态不一致

### 用 hash-based redirect

**im-router** 在建连时做精确路由——与 im-ws 内部使用**同一套虚节点一致性哈希算法**：

```go
// im-router 核心逻辑 (~50行)
// 与 Zig 版 hash_ring.zig 算法完全一致: FNV-1a + 150 vnodes + 二分查找

const vnodesPerNode = 150

type vnode struct {
    hash   uint32
    nodeID uint8
}

type HashRing struct {
    vnodes []vnode
    local  uint8
}

func (r *HashRing) addNode(nodeID uint8) {
    for vi := uint16(0); vi < vnodesPerNode; vi++ {
        seed := fmt.Sprintf("%d-%d", nodeID, vi)
        h := fnv32(seed)
        r.vnodes = append(r.vnodes, vnode{h, nodeID})
    }
    sort.Slice(r.vnodes, func(i, j int) bool {
        return r.vnodes[i].hash < r.vnodes[j].hash
    })
}

func (r *HashRing) route(userID uint64) uint8 {
    keyHash := uint32(fnv64(userID))
    if len(r.vnodes) == 0 || keyHash > r.vnodes[len(r.vnodes)-1].hash {
        return r.vnodes[0].nodeID
    }
    // 二分查找顺时针最近虚节点
    i := sort.Search(len(r.vnodes), func(i int) bool {
        return r.vnodes[i].hash >= keyHash
    })
    return r.vnodes[i].nodeID
}

func handler(w http.ResponseWriter, r *http.Request) {
    uid := parseUint(r.URL.Query().Get("uid"))
    token := r.URL.Query().Get("token")
    // validateJWT(token, uid) ...
    node := ring.route(uid)
    port := basePort + int(node)
    json.NewEncoder(w).Encode(map[string]interface{}{
        "url":  fmt.Sprintf("ws://%s:%d/ws", domain, port),
        "node": node,
    })
}
```

**同一用户永远落在同一个 Pod。** 消息发送时只需查本地 sessions hashmap (O(1))。

### 两层 hash

| 层 | 位置 | 算法 | 用途 |
|----|------|------|------|
| 建连路由 | im-router | 虚节点一致性哈希 | 首次建连 redirect |
| Pod 内校验 | im-ws | 虚节点一致性哈希 (同算法) | 扩容减震，防 ring 漂移 |

**两层用同一套算法。** 建连时 im-router 路由到 Pod-0，Pod-0 内部哈希又确认自己就是目标——扩容时两层同步变化，不会出现 "router 说去 Pod-0，Pod-0 说去 Pod-1" 的漂移。

## Pod 内部互发现

### Headless DNS

StatefulSet 配合 `clusterIP: None` 的 headless service，为每个 Pod 生成固定 DNS：

```
im-ws-0.im-ws-headless.gw.svc.cluster.local
im-ws-1.im-ws-headless.gw.svc.cluster.local
im-ws-2.im-ws-headless.gw.svc.cluster.local
```

Pod 启动时从 `POD_NAME` 环境变量解析 ordinal (`im-ws-2` → `2`)，初始化一致性哈希环。

### 跨 Pod 消息投递

当 user_1 在 Pod-0 发消息给 user_2 在 Pod-1：

```
1. Pod-0 查本地 sessions → user_2 不在
2. HashRing.route(user_2) → 目标 Pod = im-ws-1
3. HTTP POST http://im-ws-1.im-ws-headless:9090/internal/msg
   → Worker 线程执行, fire-and-forget
4. Pod-1 收到 → sessions.getByUser(user_2)
   → 在线 → sendWsFrame
   → 离线 → 忽略 (NATS 已存)
```

**关键：跨 Pod 用 HTTP 直连，不走 NATS 广播。** 每条消息最多 1 次 HTTP 转发（如果目标不在当前 Pod），而不是 ×N 次 NATS 分发。

## 为什么不用 NATS 做路由

| | NATS 广播 (v0) | HTTP 直连 (v1) |
|---|---|---|
| 消息路径 | im-ws → NATS → N 个 im-ws | im-ws → HTTP → 1 个目标 im-ws |
| 消息量 | ×N | ×1 |
| JSON parse 量 | 每个 Pod 1 次 | 仅目标 Pod 1 次 |
| 代理在热路径 | NATS 在每条消息 | 无 |
| 扩容影响 | 全部断连 + NATS 风暴 | 25% 断连 |

NATS 仅用于**离线消息持久化**。在线消息走 HTTP 直连。

## 一致性哈希环 (Hash Ring)

### 虚节点方案

```
每个物理节点占 150 个虚节点，分散在环上:
  虚节点位置: hash32("{node_id}-{vi}")  for vi in 0..149
  路由: hash64(user_id) → 截取低 32 位 → 环上二分查找 → 顺时针最近虚节点
```

**为什么比取模好：**

| 指标 | 取模 % N | 虚节点环 |
|------|----------|----------|
| 3→4 用户迁移率 | 75% | ~25% |
| 重连风暴 | 75%用户同时断连 | 25%用户分批断连 |
| 缩容 | 全部重分配 | 被删节点的 key 顺移给邻居 |

### 初始化

```zig
const sws = @import("sws");
// im-ws 启动时
pub fn initRing(alloc: std.mem.Allocator, local_id: u8) !sws.HashRing {
    var ring = sws.HashRing.init(alloc, local_id);
    try ring.addNode(0);
    try ring.addNode(1);
    try ring.addNode(2);
    return ring;
}
```

### 建连校验

im-router 已用 `hash % N` 做第一次路由，Pod 内做二次校验防 ring 漂移：

```zig
fn wsOnConnect(ring: *sws.HashRing, local_id: u8, user_id: u64) bool {
    if (ring.routeIsRemote(sws.hash64(std.mem.asBytes(&user_id)))) {
        return false; // ring 漂移，发 redirect
    }
    return true;
}
```

## 扩容操作

### 3 → 4 节点

```bash
# 1. 添加新 Pod 的 NodePort (新增 im-ws-3-np, 端口 30004)
kubectl apply -f nodeports.yaml

# 2. 扩展 StatefulSet
kubectl scale statefulset im-ws --replicas=4 -n gw

# 3. 滚动重启 im-ws 和 im-router (应用新 ring: addNode(3))
kubectl rollout restart statefulset im-ws -n gw
kubectl rollout restart deployment im-router -n gw
# → 新 Pod 上线，im-router 更新环 (addNode(3))
# → 两层都切到 4 节点环，~25% 用户迁移
```

### 缩容 4 → 3

```bash
# 1. 更新 ring: removeNode(3) → 滚动重启两者
kubectl rollout restart statefulset im-ws -n gw
kubectl rollout restart deployment im-router -n gw
# → 环同时移除节点 3，被删节点的用户迁移到邻居

# 2. 缩容
kubectl scale statefulset im-ws --replicas=3 -n gw

# 3. 删除多余的 NodePort service
kubectl delete svc im-ws-3-np -n gw
```

## 资源预估

### 单 Pod (1C / 2GB)

```
StackPool:     1M × 384B = 400MB    (连接槽位)
BufferPool:    64MB                  (io_uring slab)
LargeBuffer:   64MB                  (64 × 1MB 块)
Freelist:      4MB
NATS session:  ~2MB
OS + 其他:     ~400MB
剩余可用:      ~1GB
```

| 场景 | 连接数 | CPU | 说明 |
|------|--------|-----|------|
| 空闲 | 1M | ~0% | 纯 TCP 无消息 |
| 1% 活跃 | 10K 发消息 | ~3% | 20K CQE/s |
| 3% 活跃 | 30K 发消息 | ~8% | 60K CQE/s |
| 10% 活跃 | 100K 发消息 | ~25% | 200K CQE/s |
| 安全上限 | ~300K | <30% | 留余量 |

### im-router (10m CPU / 16Mi RAM)

```
每个 redirect 请求: ~2KB
2 副本 → ~5K req/s
建连峰值 10K 用户同时上线 → 轻松扛
```

## 故障恢复

| 故障 | 行为 | 恢复时间 |
|------|------|----------|
| Pod 宕机 | StatefulSet 自动重建同名 Pod | ~5s |
| 旧连接断连 | 客户端 onclose → 重连 → redirect | 客户端重试 |
| Node 宕机 | Pod 迁移到其他 Node (IP 变) | ~30s |
| DNS | NodeIP 不变，NodePort 在所有 Node 生效 | 无影响 |
| NATS 宕机 | 消息发送失败 → 客户端报错 | NATS 恢复后 pull 离线消息 |

## 为什么选 sws 而不是 Rust/Erlang

| | sws (Zig) | Rust (tokio) | Erlang/Elixir |
|---|---|---|---|
| 单 Pod 连接数 | 1M (StackPool) | ~50K (per-fiber stack) | ~100K (per-process heap) |
| 内存 / 连接 | 384B | ~16KB | ~2KB |
| 启动时间 | ~5ms (无预热) | ~500ms (runtime init) | ~2s (BEAM start) |
| CPU 绑核 | 0 开销 | 需要 CPU affinity | 无原生支持 |
| io_uring | 原生直连 | 有 (tokio-uring) | 无 |
| 二进制大小 | ~500KB | ~5MB | ~20MB |
| 运行时 | 无 | async runtime | BEAM VM |

**关键差异是连接密度。** tokio 的 per-fiber 独立栈决定了连接上限受内存约束——1M 连接 × 16KB = 16GB 内存。sws 的 Fiber 共享栈 (256KB) + StackPool (384B/连接) 让 1M 连接只需 ~500MB。这个差异不是工程优化能弥补的，是架构上的根本取舍。
