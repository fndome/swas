# PENDING_REVIEW

> 审计状态：第一波 PR 已合并（2026-05-09），第二轮修复已完成。
> 当前基于 commit `949e441` + 本地修复。GPT 第二/三波尚未推送。

---

## 第一波 PR 已修复项 (✅ done)

从 GPT-5.5 聊天记录核对，以下问题已在第一波中修复：

| # | 问题 | 修复位置 |
|---|------|----------|
| 1 | Fiber x86_64 栈对齐错误（rsp 未模拟 ABI -8 对齐） | `src/next/fiber.zig:50` |
| 2 | HTTP client 多 fiber 共用全局 active_pipe 导致串包 | `src/client/http_client.zig:111-116` → `pipeForStream()` |
| 3 | keep-alive 响应等 EOF 挂死，未按 Content-Length 判断边界 | `src/client/http_client.zig:94-97` → `responseCompleteLen()` |
| 4 | io_uring LINK_TIMEOUT 用了栈变量地址 (use-after-return) | `src/shared/tcp_stream.zig:30,144` → 持久字段 `connect_timeout_ts` |
| 5 | server.stop() 跨线程普通 bool 写入，数据竞争 | `src/http/event_loop.zig:25` → `@atomicStore(.release)` |
| 6 | io_uring SINGLE_ISSUER 导致跨线程 init/run 报 InvalidThread | `src/http/async_server.zig:250-252` → 去掉了 SINGLE_ISSUER 标志 |
| 7 | Request body 复用 response body 字段（POST 被误判已响应） | `src/http/context.zig:9` → 新增 `request_body` 字段 |
| 8 | getHeader("Host") 误匹配 "Hostile" | `src/http/context.zig:68` → 要求 `:` 紧跟 header 名 |
| 9 | ctx.query() 只取了 method 部分，永远取不到参数 | `src/http/context.zig:82-84` → 从 URI 部分提取 |
| 10 | 路由 fast path 把 query string 一起参与路径匹配 | `src/http/tcp_read.zig:133-134` → 取 `?` 前部分 |
| 11 | `\n\n` header 分隔符下 body 起点计算错误 | `src/http/tcp_read.zig:141-143` → 区分 CRLF / LF-only |
| 12 | Content-Length 小写无法识别 | `src/http/tcp_read.zig:145-148` → 大小写不敏感 |
| 13 | 跨 TCP 分片拼 header 后栈内存交给 fiber（悬空指针） | `src/http/tcp_read.zig:364-371` → 堆复制 + `request_data_owned` |
| 14 | Next.push 任务生命周期：入队失败时 pool/大块缓冲泄漏 | `src/http/http_routing.zig:324-327`, `src/http/ws_handler.zig:251-254` |
| 15 | DNS A 记录 IP 未转网络字节序 | `src/dns/packet.zig:145` → `nativeToBig()` |
| 16 | parseIpv4 返回值未转网络字节序导致 bind 地址错 | `src/http/http_helpers.zig:95` → `nativeToBig()` |

---

## 第二轮本地修复 (✅ done)

| # | 问题 | 修复文件 | 改动 |
|---|------|----------|------|
| H1 | `waiting_computation` 状态未处理 → 误杀连接 | `src/http/event_loop.zig` | 新增 `.waiting_computation` 分支，仅 replenish buffer |
| H2 | `makeErrorResponse` 三级回退 `&.{}` 被 free → UB | `src/client/http_client.zig` | `Response.deinit()` 前检查 `body.len > 0` |
| H3 | manual mutex state 操作 + `cond` 未使用 | `src/client/http_client.zig` | 移除 `mutex`/`cond`，改用 `@atomicLoad`/`@atomicStore` |
| M1 | `encodeName` 静默跳过非法标签 | `src/dns/packet.zig` | 返回 `error.LabelTooLong` / `error.EmptyLabel` |
| M2 | middleware 遍历 3 处重复 | `src/http/http_fiber.zig` | 提取 `runMiddlewareList` 公共函数 |
| M3 | `tcp_outbound_ring` 每次 I/O 单独 submit | `src/outbound/tcp_outbound_ring.zig` | 移除 submitRead/submitWrite 内的 `ring.submit()` |
| M4 | `readResolvConfNameserver` + `parseIpv4` 重复定义 | `src/client/ring.zig` + `src/http/async_server.zig` | 统一到 `src/http/http_helpers.zig` |
| L1 | STRESS_TEST.md wbuf 文档错 (4KB→64KB) | `STRESS_TEST.md` | 更新 4 处过时描述 |
| L2 | typo `Nextuest` → `Request` | `src/example.zig` | 修正 |
| L3 | SIMD 非对齐路径逐字节 → 4 字节 SWAR | `src/ws/frame.zig` | `readInt(u32)` + XOR 回退 |
| L4 | `RingBuffer.push()` 仅 retry 1 次 → 8 次 | `src/spsc_ringbuffer.zig` | 循环重试 with yield |
| L5 | 64KB `resp_buf` 栈变量 → 堆分配 | `src/client/http_client.zig` | `allocator.alloc` + `defer free` |
| L6 | fixed file 注册失败静默忽略 | `src/shared/tcp_stream.zig` | 添加 `std.log.warn` |
| L7 | `parked.append` 失败后未清理资源 | `src/next/next.zig` | `releaseStack` + `destroy(task)` 兜底 |

---

## 仍存在的问题 (未修，设计层面 / 非 bug)

| # | 问题 | 说明 |
|---|------|------|
| 4 | `connection_mgr.zig` closeConn 递归自调用 | 终止条件正确 (fd==0)，但结构脆弱 |
| 8 | `ws_handler.zig` handler fiber 未完成即投递 read | `shared_fiber_active` 保护正确，耦合度高 |
| 9 | HTTP pipelining 不支持 | `tcp_read.zig` 单次 read 只处理一个请求，属功能缺失 |

---

## 后续跟踪

- [x] 第一波 PR 已合并，16 项修复已核对确认
- [x] 第二轮本地修复完成：14 项 (H1-H3, M1-M4, L1-L7)
- [ ] 等待 GPT 第二/三波 PR 推送 → 重新审计并修复
- [ ] 所有波次完成后，跑 `zig build test` 验证不引入回归
