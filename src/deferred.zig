const std = @import("std");
const Allocator = std.mem.Allocator;

/// 在链式异步 I/O 结束时向客户端发 HTTP 响应。
/// handler 设 ctx.deferred = true，链式调用末端调 resp.json/text 发回数据。
/// Worker 线程 → invokeOnIoThread(SPSC) → IO 线程写响应。
pub const DeferredResponse = struct {
    server: *@import("./http/async_server.zig").AsyncServer,
    conn_id: u64,
    allocator: Allocator,

    pub fn json(self: *const DeferredResponse, status: u16, body: []const u8) void {
        const duped = self.allocator.dupe(u8, body) catch {
            // OOM: send a best-effort error response so the client does not
            // hang indefinitely waiting for a deferred response that will
            // never arrive.
            const fallback = self.allocator.dupe(u8, "{\"error\":\"OOM\"}") catch return;
            self.server.sendDeferredResponse(self.conn_id, 500, .json, fallback);
            return;
        };
        self.server.sendDeferredResponse(self.conn_id, status, .json, duped);
    }

    pub fn text(self: *const DeferredResponse, status: u16, body: []const u8) void {
        const duped = self.allocator.dupe(u8, body) catch {
            const fallback = self.allocator.dupe(u8, "OOM") catch return;
            self.server.sendDeferredResponse(self.conn_id, 500, .plain, fallback);
            return;
        };
        self.server.sendDeferredResponse(self.conn_id, status, .plain, duped);
    }
};
