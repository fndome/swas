# REAL_BUG.md — 确认需修复的真实 Bug

> 经三轮深度推理 + 自我审计修正 + 系统原生并发模型校准后的最终清单。
> 已排除：假阳性（3个）、单线程误判（4个）、已修复（15个）、设计意图内（IO_QUANTUM）。

---

## BUG-1 [HIGH] large_buf 被 GPA 释放，绕过 LargeBufferPool

**文件**: `src/http/async_server.zig` `processBodyRequest()` + `httpTaskExec()`  
**触发**: 任何 Content-Length > 32KB 的请求

**链路**:
```
onBodyChunk → body 收齐
  → processBodyRequest(conn, buf)     // buf 来自 LargeBufferPool.acquire()
    → t.body_data = body_buf           // line ~940
      → httpTaskExec                   // line ~2474
        → ctx.body = t.body_data       // line 2481 — ctx.body 指向 large_pool 内存
        → defer ctx.deinit()           // line 2486
          → self.allocator.free(b)     // context.zig:141 — GPA 释放 Pool 内存！
```

**后果**:
- LargeBufferPool 的 `blocks[i]` 指针仍指向已被 GPA free 的内存
- 下次 `acquire()` 返回同一个 block → **use-after-free**
- `deinit()` 时尝试再次 free 同一 block → **double-free**
- 每次触发后池容量永久减 1

**根因**: `Context.body` 字段不区分来源（GPA dupe vs Pool 指针）。`deinit()` 默认用 GPA 释放。

**修复方向**: 在 `processBodyRequest` 的 has_async 路径中，不通过 `t.body_data` 传递 large_buf。改为：handler 运行时 large_buf 保持存活，handler 结束后由 `processBodyRequest` 的调用链负责释放。或者给 Context 加 `body_owned_by_pool: bool` 标记。

---

## BUG-2 [MEDIUM] connFree 不校验 gen_id 直接释放 slot

**文件**: `src/stack_pool_sticker.zig` `connFree()` line 278  
**触发**: 同一连接被 close 两次（close CQE + 读 CQE 几乎同时到达）

**链路**:
```
dispatchCqes:
  close CQE 到达 → closeConn(0) → connFree(pool, conn_id) → slotFree(idx)
  读 CQE 到达    → onReadComplete → 可能再触发 closeConn
```
如果 slot 在两次 close 之间被重用（新连接分配了同一 idx，gen_id 已变化），
第二次 `slotFree` 会清零新连接的 gen_id，破坏新连接。

**修复**: `connFree` 或 `slotFree` 调用前加 gen_id 校验。
```zig
if (slot.line1.gen_id != conn.gen_id) return;  // slot 已被重用，不是此连接
```

---

## BUG-3 [MEDIUM] writev_in_flight guard 静默返回（已在 PRE_AMEND_AUDIT 中修复）

**状态**: ✅ 已修复。`return` → `return error.WriteInFlight`。

---

## BUG-4 [MEDIUM] ChunkStream dispatch 大 feed 时静默截断数据

**文件**: `src/next/chunk_stream.zig` `dispatch()`  
**触发**: `feed(data)` 中 data.len 远超 `threshold`（worker_buf.len）

**链路**:
```
feed(data) with data.len = 200KB, threshold = 64KB
  → offset 从 0 → 200KB (space 足够)
  → offset >= threshold → dispatch()
    → copy_len = min(200KB, 64KB) = 64KB
    → offset = 0  ← 丢弃了 136KB！
```

**根因**: `feed()` 不按 threshold 边界拆包。单次大 feed 会越过 dispatch 触发点，超过 worker_buf 的部分被丢弃。

**修复**: `feed()` 中当 `n + self.offset > self.threshold` 时，先 dispatch 当前累积的数据，再继续 feed 剩余部分。
```zig
// 伪代码
while (data.len > 0) {
    const space = self.large_buf.len -| self.offset;
    const n = @min(@min(data.len, space), self.threshold -| self.offset);
    @memcpy(self.large_buf[self.offset..][0..n], data[0..n]);
    self.offset += n;
    data = data[n..];
    if (self.offset >= self.threshold) self.dispatch();
}
```

---

## BUG-5 [LOW] WorkerPool stack_freelist 竞争（仅 n > 1 worker 时触发）

**文件**: `src/next/next.zig` `acquireStack()` / `releaseStack()`  
**触发**: `initPool4NextSubmit(n)` 且 n > 1

**链路**: 多个 worker 线程同时访问 `stack_freelist_top` 和 `stack_freelist[]`，
无互斥锁保护。`acquireStack` 的 read-dec-write 和 `releaseStack` 的 write-inc
在同一 `freelist_top` 上竞争。

**实际影响**: 默认 `n = 1`（README 推荐）→ 不触发。`n > 1` → freelist 损坏，
两个 fiber 可能被分配到同一块栈内存。

**修复**: `acquireStack` / `releaseStack` 加 `pool.mutex` 保护，或文档明确标注"仅支持 n=1"。

---

## BUG-6 [LOW] DNS skipName 压缩指针无限循环

**文件**: `src/dns/packet.zig` `skipName()`  
**触发**: 恶意 DNS 响应包含自指压缩指针（`0xC0 0x00`）

**链路**:
```
skipName 遇到 0xC0 0x00 → off = start + 2（回到原位）
→ while (off < packet.len) → 再次遇到 0xC0 0x00 → 无限循环
```
packet.len ≤ 512，最多循环 256 次，但每轮调用 skipName（外层 parseResponse 也循环）。

**修复**: 加 jump count 上限。
```zig
var jumps: u8 = 0;
while (off < packet.len) {
    if (packet[off] & 0xC0 == 0xC0) {
        jumps += 1;
        if (jumps > 10) return packet.len;
        return off + 2;
    }
    ...
}
```

---

## BUG-7 [LOW] WS close 帧响应后不主动关闭连接

**文件**: `src/http/async_server.zig` `onWsFrame()` `.close` branch  
**触发**: 任何 WebSocket close 帧

**链路**:
```
收到 close → 发 close 响应 → conn.state = .ws_writing
写完成 → flushWsWriteQueue → conn.state = .ws_reading + submitRead
```
连接应该在 close 帧交换后关闭，不应继续读。

**修复**: close 帧写完成后 `closeConn(conn_id, conn.fd)`，而非 `submitRead`。

---

## BUG-8 [LOW] AsyncServer.deinit 不释放 large_pool 中被占用的 buffer

**文件**: `src/http/async_server.zig` `deinit()`  
**触发**: deinit 时有连接在 `.receiving_body` 状态

**链路**: deinit 遍历连接释放 write_body/ws_token/response_buf，但不释放 `large_buf_ptr`。
`large_pool.deinit()` 后面执行，此时 `blocks` 中仍有标记为 BUSY 的块 → 泄漏。

**修复**: deinit 遍历时检查 `pool_idx` 对应的 Slot，若 `large_buf_ptr != 0` 则 `large_pool.release`。

---

## BUG-9 [LOW] keep-alive 判定过度乐观

**文件**: `src/http/async_server.zig` `onReadComplete()` → `isKeepAliveConnection()`  
**触发**: HTTP/1.1 客户端未显式发送 `Connection: keep-alive`

**链路**: `isKeepAliveConnection` 对 HTTP/1.1 默认返回 true。但部分老式 HTTP/1.1
实现不支持 keep-alive。连接会挂起直到 TTL 超时。

**修复**: 默认 `keep_alive = false`，由 `isKeepAliveConnection` 显式设为 true。

---

## BUG-10 [LOW] Content-Length 负数静默忽略

**文件**: `src/http/context.zig` `getContentLength()` line 118  
**触发**: 客户端发送 `Content-Length: -1`

**链路**: `parseInt(usize, "-1")` 失败 → catch 返回 0 → body 被忽略。
应返回 400 Bad Request。

**修复**: 解析失败时返回 error 或标记为无效。

---

## BUG-11 [LOW] RingSharedClient connect 双重 submit

**文件**: `src/shared/tcp_stream.zig` `submitPollOut()`  
**触发**: connect 立即失败（端口未监听）

**链路**:
```
1. ring.submit() 提交 CONNECT SQE (line 141)
2. CQE 立即到达 → state = .closing/connected
3. 代码继续执行到 line 144-153 → 创建 LINK_TIMEOUT SQE
4. ring.submit() 提交 LINK_TIMEOUT (line 152)
5. LINK_TIMEOUT 成为孤儿 SQE → 超时后产生无用 CQE
```

**修复**: 将 CONNECT + LINK_TIMEOUT 放在同一次 submit 中。

---

## BUG-12 [LOW] RingB deinit 不通知等待中的 DNS fiber

**文件**: `src/client/ring.zig` `deinit()`  
**触发**: deinit 时有进行中的 DNS 查询

**链路**: `self.dns.deinit()` 清空 DnsResolver，但 `self.dns.pending` hashmap
中仍有等待的 fiber。deinit 后 fiber resume 时访问已释放的 DnsYieldSlot。

**修复**: deinit 前遍历 pending，对每个 entry 设空结果并 resume。

---

## 汇总

| # | 严重度 | 位置 | 一句话 |
|---|--------|------|--------|
| BUG-1 | HIGH | async_server.zig | large_buf 被 GPA 释放，绕过 LargeBufferPool |
| BUG-2 | MEDIUM | sticker.zig | connFree 不校验 gen_id |
| BUG-3 | MEDIUM | async_server.zig | ✅ 已修复 (writev_in_flight guard) |
| BUG-4 | MEDIUM | chunk_stream.zig | feed() 大包不拆包导致 dispatch 截断 |
| BUG-5 | LOW | next.zig | 多 worker 时 stack_freelist 竞争 |
| BUG-6 | LOW | dns/packet.zig | skipName 压缩指针循环 |
| BUG-7 | LOW | async_server.zig | WS close 后不主动关闭 |
| BUG-8 | LOW | async_server.zig | deinit 不释放 active large_buf |
| BUG-9 | LOW | async_server.zig | keep-alive 默认 true |
| BUG-10 | LOW | context.zig | Content-Length 负数返回 0 |
| BUG-11 | LOW | tcp_stream.zig | connect 双重 submit |
| BUG-12 | LOW | client/ring.zig | deinit 不通知 DNS fiber |

**需立即修复**: BUG-1（每次 >32KB 请求触发 crash/double-free）
**建议修复**: BUG-2, BUG-4（中等概率触发，后果严重）
**择机修复**: BUG-5~12（低概率或仅影响边界场景）
