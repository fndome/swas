# IM-WS K8s 部署指南

## 架构概览

```
                         K8s Cluster
 Client                    ┌────────────────────────────────────────────┐
 ── wss://ws.example.com:30443/ws?uid=123456&token=xxx ──┐            │
                           │                               ▼            │
                           │              ┌─────────────────────────┐  │
                           │              │   im-router (Go)        │  │
                           │              │   router_hash 算法      │  │
                           │              │   hash(uid) → ordinal   │  │
                           │              │   → IP:PORT redirect    │  │
                           │              └────────────┬────────────┘  │
                           │                           │               │
                           │  {"url":"wss://ws.example.com:30001/ws"}  │
 ← redirect ───────────────┘                           │               │
                                                       │               │
 ── wss://ws.example.com:30001/ws ─────────────────────┼──┐           │
                           │                           │  │           │
                           │              ┌────────────▼──▼────────┐  │
                           │              │   NodePort 30001       │  │
                           │              │   eBPF DNAT → PodIP    │  │
                           │              └────────────┬───────────┘  │
                           │                           │              │
                           │   ┌───────────────────────┼───────────┐  │
                           │   │  Node-A           Node-B     Node-C │  │
                           │   │  ┌──────────┐  ┌──────────┐ ...    │  │
                           │   │  │ im-ws-0  │  │ im-ws-1  │       │  │
                           │   │  │ pod_hash │  │ pod_hash │       │  │
                           │   │  │ :9090     │  │ :9090     │       │  │
                           │   │  └────┬─────┘  └────┬─────┘       │  │
                           │   │       │              │              │  │
                           │   │       └──────┬───────┘              │  │
                           │   │              │  HTTP 直连           │  │
                           │   │              │  Headless DNS        │  │
                           │   │              │  im-ws-{N}.im-ws-    │  │
                           │   │              │  headless             │  │
                           │   └──────────────┼──────────────────────┘  │
                           │                  │                         │
                           │           ┌──────▼──────┐                  │
                           │           │    NATS     │                  │
                           │           │  JetStream  │                  │
                           │           │  离线消息    │                  │
                           │           └─────────────┘                  │
                           └────────────────────────────────────────────┘
```

## 两个 Hash 文件，两种路由

| 文件 | 角色 | hash 输出 | 调用方 |
|------|------|----------|--------|
| `pod_hash.zig` | Pod 侧 | `im-ws-{N}.im-ws-headless` (K8s DNS) | im-ws Pod 转发消息 |
| `router_hash.zig` | Router 侧 | `wss://DOMAIN:{30001+N}/ws` (IP:PORT) | im-router 建连 redirect |

两文件使用**完全相同**的核心算法: FNV-1a + 150 虚节点 + 二分查找。同一 `user_id` 在两端路由到同一 ordinal。

### pod_hash.zig — DNS 路由

```zig
// 消息转发: hash(to_uid) → 目标 Pod DNS
var ring = HashRing.init(alloc, pod_ordinal);
try ring.addNode(0); try ring.addNode(1); try ring.addNode(2);

var dns_buf: [64]u8 = undefined;
const target = ring.routeToPod(to_uid, "im-ws-{d}.im-ws-headless", &dns_buf);
// → ordinal=1, dns="im-ws-1.im-ws-headless"
// → getaddrinfo(dns) → Pod IP → connect
```

### router_hash.zig — IP:PORT 路由

```zig
// 建连 redirect: hash(uid) → 目标 NodePort URL
var ring = HashRing.init(alloc);
try ring.addNode(0); try ring.addNode(1); try ring.addNode(2);

var url_buf: [128]u8 = undefined;
const addr = ring.routeToAddr(uid, "ws.example.com", 30001, &url_buf);
// → ordinal=0, url="wss://ws.example.com:30001/ws"
// → 返回给客户端 → 客户端直连
```

## 核心算法 (两端一致)

```
常量: VIRTUAL_NODES_PER_NODE = 150

hash64(user_id: u64) → FNV-1a 64-bit:
  初始: h = 0xcbf29ce484222325
  循环 8 字节 (little-endian):
    h ^= byte; h *= 0x100000001b3

trunc32: 取低 32 位 (h & 0xFFFFFFFF)

hash32(vnode_seed: []u8) → FNV-1a 32-bit:
  初始: h = 0x811c9dc5
  循环每字节:
    h ^= byte; h *= 0x01000193

路由: trunc32(hash64(uid)) → 环上二分查找 → 顺时针最近虚节点 → node_id
```

## ConfigMap 统一参数管理

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: im-cluster-config
data:
  NODE_COUNT: "3"                          # = StatefulSet replicas
  NODEPORT_BASE: "30001"                   # nodeports.yaml 起始端口
  DOMAIN: "ws.example.com"                 # redirect URL 域名
  POD_DNS_FMT: "im-ws-{d}.im-ws-headless"  # Pod 间 DNS 模板
```

im-router 和 im-ws 均通过 `envFrom.configMapRef: im-cluster-config` 注入。

## 部署顺序

```bash
# 1. Namespace + ConfigMap
kubectl apply -f deploy-im-ws.yaml

# 2. DNS 配置 (手动)
#    ws.example.com A → Node1-IP, Node2-IP, Node3-IP
#    端口区分 Pod: 30001→im-ws-0, 30002→im-ws-1, 30003→im-ws-2
```

## 扩容操作 (3→4)

```bash
# 1. 改 ConfigMap
kubectl edit configmap im-cluster-config -n gw
# NODE_COUNT: "3" → "4"

# 2. 扩 StatefulSet
kubectl scale statefulset im-ws --replicas=4 -n gw

# 3. 添加 NodePort (如 nodeports.yaml 未预留)
#    im-ws-3-np → nodePort: 30004

# 4. 滚动重启两者 (重建 hash ring)
kubectl rollout restart statefulset im-ws -n gw
kubectl rollout restart deployment im-router -n gw
# → ~25% 用户迁移，75% 回原 Pod
```

## 缩容操作 (4→3)

```bash
# 1. 改 ConfigMap: NODE_COUNT=3
# 2. 重启两者 (ring.removeNode)
# 3. 缩 StatefulSet --replicas=3
# 4. 删除多余 NodePort
```

## 一节点一 Pod

StatefulSet 配置 podAntiAffinity:
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: im-ws
      topologyKey: kubernetes.io/hostname
```

扩容到 > Node 数量时，新 Pod 将 Pending（需先扩容 Node）。

## 资源预估

### 单 Pod (1C / 2GB)

| 场景 | 连接数 | CPU |
|------|--------|-----|
| 空闲 | 1M | ~0% |
| 1% 活跃 | 10K | ~3% |
| 3% 活跃 | 30K | ~8% |
| 10% 活跃 | 100K | ~25% |
| 安全上限 | ~300K | <30% |

### im-router (10m CPU / 16Mi RAM)

纯 HTTP redirect, 2 副本 → ~5K req/s

## 故障恢复

| 故障 | 行为 | 恢复 |
|------|------|------|
| Pod 宕机 | StatefulSet 自动重建同名 Pod | ~5s |
| Node 宕机 | Pod 迁移, NodePort 在所有 Node 生效 | ~30s |
| NATS 宕机 | 消息发送失败, 不丢 (已持久化) | NATS 恢复后 pull |
| ConfigMap 改错 | hash 环不一致 → 路由漂移 | 修正 ConfigMap 后重启 |

## 为什么选 sws 而不是 Rust/Erlang

| | sws (Zig) | Rust (tokio) | Erlang/Elixir |
|---|---|---|---|
| 单 Pod 连接数 | 1M | ~100K | ~100K |
| 内存 / 连接 | 384B | ~1.5KB (极限调优) / 16KB (默认) | ~2KB |
| 1M 连接需内存 | **600MB** | **1.5GB** (极限) / **16GB** (默认) | **2GB** |
| 启动时间 | ~5ms | ~500ms | ~2s |
| io_uring | 原生 | tokio-uring | 无 |
| 二进制 | ~500KB | ~5MB | ~20MB |

> tokio 的 1.5KB/conn 需要大幅调优 stack size + 规避 per-task 堆分配, 实际生产通常不敢压这么低。
