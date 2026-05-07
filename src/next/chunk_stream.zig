const std = @import("std");
const Allocator = std.mem.Allocator;
const DeferredResponse = @import("../deferred.zig").DeferredResponse;
const Next = @import("next.zig").Next;

pub const ProcessFn = *const fn (ctx: ?*anyopaque, chunk: []const u8, resp: *DeferredResponse) void;

pub const StreamHandle = struct {
    const Self = @This();

    large_buf: []u8,            // IO 写目标: LargeBufferPool 1MB
    worker_buf: []u8,           // Worker 读目标: init 一次分配, dispatch 复用
    offset: usize,              // 已攒字节数
    threshold: usize,           // 触发 dispatch 的字节阈值
    eof: bool,                  // 流已结束
    job_id: u64,
    slot_idx: u32,
    resp: *DeferredResponse,
    process_fn: ProcessFn,
    process_ctx: ?*anyopaque,

    const CHUNK_DEFAULT: usize = 65536;

    pub fn init(large_buf: []u8, threshold: usize, slot_idx: u32, resp: *DeferredResponse, process_fn: ProcessFn, process_ctx: ?*anyopaque) Self {
        const thresh = if (threshold == 0) CHUNK_DEFAULT else threshold;
        const wbuf = resp.allocator.alloc(u8, thresh) catch @panic("StreamHandle: OOM");
        return .{
            .large_buf = large_buf,
            .worker_buf = wbuf,
            .offset = 0,
            .threshold = thresh,
            .eof = false,
            .job_id = 0,
            .slot_idx = slot_idx,
            .resp = resp,
            .process_fn = process_fn,
            .process_ctx = process_ctx,
        };
    }

    pub fn deinit(self: *Self) void {
        self.resp.allocator.free(self.worker_buf);
        self.worker_buf = &.{};
    }

    pub fn feed(self: *Self, data: []const u8) bool {
        if (self.eof) return false;
        const space = self.large_buf.len -| self.offset;
        if (space == 0) { self.dispatch(); return self.feed(data); }
        const n = @min(data.len, space);
        @memcpy(self.large_buf[self.offset..][0..n], data[0..n]);
        self.offset += n;
        if (self.offset >= self.threshold) { self.dispatch(); return true; }
        return false;
    }

    pub fn finish(self: *Self) bool {
        self.eof = true;
        if (self.offset > 0) { self.dispatch(); return true; }
        return false;
    }

    fn dispatch(self: *Self) void {
        if (self.offset == 0) return;
        @memcpy(self.worker_buf[0..self.offset], self.large_buf[0..self.offset]);
        const chunk_len = self.offset;
        self.offset = 0;

        const ctx = ChunkDispatchCtx{
            .chunk = self.worker_buf.ptr,
            .chunk_len = chunk_len,
            .process_fn = self.process_fn,
            .process_ctx = self.process_ctx,
            .resp = self.resp,
            .job_id = self.job_id,
            .slot_idx = self.slot_idx,
        };
        Next.submit(ChunkDispatchCtx, ctx, runChunkWorker);
    }
};

fn runChunkWorker(c: *ChunkDispatchCtx, complete: *const fn (?*anyopaque, []const u8) void) void {
    _ = complete;
    const chunk = c.chunk[0..c.chunk_len];
    c.process_fn(c.process_ctx, chunk, c.resp);
}

const ChunkDispatchCtx = struct {
    chunk: [*]u8,
    chunk_len: usize,
    process_fn: ProcessFn,
    process_ctx: ?*anyopaque,
    resp: *DeferredResponse,
    job_id: u64,
    slot_idx: u32,
};
