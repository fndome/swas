const std = @import("std");
const Allocator = std.mem.Allocator;
const DeferredResponse = @import("../root.zig").DeferredResponse;
const Next = @import("next.zig").Next;

/// ── ChunkStream: IO线程搬运 + Worker线程解析 ──────────────
///
/// 编程模型:
///   IO 线程: 每收到一块数据 → memcpy到large_buf → 攒到threshold → dispatch
///   Worker 线程: 收到chunk → 解析协议 → DeferredResponse.json()
///
/// 身份锚定: slot_idx → slot → connection → 知道这段数据属于谁
///
/// 适用场景:
///   - MySQL 500行结果集 (IO拷贝, Worker解析行协议)
///   - NATS 200KB JSON (IO拷贝, Worker json.parse)
///   - 本地大文件 (IO read, Worker分段处理)
///   - HTTP body流式上传 (IO拷贝, Worker逐块处理)
///
/// 用法:
///   const stream = StreamHandle.init(large_buf, 65536, slot_idx, resp, processFn, ctx);
///   StreamHandle.attachToSlot(slot, &stream);
///   // 此后 Sticker 在 onRead 路径自动 feed → dispatch

pub const ProcessFn = *const fn (ctx: ?*anyopaque, chunk: []const u8, resp: *DeferredResponse) void;

pub const StreamHandle = struct {
    const Self = @This();

    large_buf: []u8,            // 从 LargeBufferPool 拿的 1MB 块
    offset: usize,              // 已攒字节数
    threshold: usize,           // 触发 dispatch 的字节阈值
    eof: bool,                  // 流已结束
    job_id: u64,                // 查询/任务标识
    slot_idx: u32,              // 锚定 slot
    resp: *DeferredResponse,    // Worker 线程用此发 HTTP 响应
    process_fn: ProcessFn,      // Worker 线程执行的解析回调
    process_ctx: ?*anyopaque,   // 透传给 process_fn

    const CHUNK_DEFAULT: usize = 65536;

    pub fn init(
        large_buf: []u8,
        threshold: usize,
        slot_idx: u32,
        resp: *DeferredResponse,
        process_fn: ProcessFn,
        process_ctx: ?*anyopaque,
    ) Self {
        return .{
            .large_buf = large_buf,
            .offset = 0,
            .threshold = if (threshold == 0) CHUNK_DEFAULT else threshold,
            .eof = false,
            .job_id = 0,
            .slot_idx = slot_idx,
            .resp = resp,
            .process_fn = process_fn,
            .process_ctx = process_ctx,
        };
    }

    /// Sticker 在每次读完成时调用。
    /// 返回 true 表示触发了一次 dispatch。
    pub fn feed(self: *Self, data: []const u8) bool {
        if (self.eof) return false;

        const space = self.large_buf.len -| self.offset;
        if (space == 0) {
            // Buffer full — force dispatch
            self.dispatch();
            return self.feed(data);
        }

        const n = @min(data.len, space);
        @memcpy(self.large_buf[self.offset..][0..n], data[0..n]);
        self.offset += n;

        if (self.offset >= self.threshold) {
            self.dispatch();
            return true;
        }
        return false;
    }

    /// 发送方通知流结束。剩余未发完的数据会被 dispatch。
    pub fn finish(self: *Self) bool {
        self.eof = true;
        if (self.offset > 0) {
            self.dispatch();
            return true;
        }
        return false;
    }

    /// 向 WorkerPool 派发当前积累的 chunk。
    ///  chunk 指针指向 large_buf[0..offset]，Worker 解析期间 buf 稳定。
    ///  dispatch 后 offset 重置为 0，下一轮复用同一块 buf 的前端。
    fn dispatch(self: *Self) void {
        if (self.offset == 0) return;

        const ctx = ChunkDispatchCtx{
            .chunk_ptr = self.large_buf.ptr,
            .chunk_len = self.offset,
            .process_fn = self.process_fn,
            .process_ctx = self.process_ctx,
            .resp = self.resp,
            .job_id = self.job_id,
            .slot_idx = self.slot_idx,
        };
        self.offset = 0;

        Next.submit(
            ChunkDispatchCtx,
            ctx,
            runChunkWorker,
        );
    }
};

/// WorkerPool 线程执行的入口。
/// 收到的是什么字节就原样传给用户回调，不做任何协议解读。
fn runChunkWorker(
    c: *ChunkDispatchCtx,
    complete: *const fn (?*anyopaque, []const u8) void,
) void {
    _ = complete;
    const chunk = c.chunk_ptr[0..c.chunk_len];
    c.process_fn(c.process_ctx, chunk, c.resp);
}

const ChunkDispatchCtx = struct {
    chunk_ptr: [*]const u8,
    chunk_len: usize,
    process_fn: ProcessFn,
    process_ctx: ?*anyopaque,
    resp: *DeferredResponse,
    job_id: u64,
    slot_idx: u32,
};
