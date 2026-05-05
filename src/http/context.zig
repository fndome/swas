const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Context = struct {
    pub const ContentType = enum { plain, json, html };

    request_data: []const u8,
    path: []const u8,
    app_ctx: ?*anyopaque,

    status: u16 = 200,
    content_type: ContentType = .plain,
    body: ?[]u8 = null,
    headers: ?std.ArrayList(u8) = null,

    allocator: Allocator,

    conn_id: u64 = 0,
    deferred: bool = false,
    server: ?*anyopaque = null,

    pub fn json(self: *Context, status: u16, value: anytype) !void {
        self.status = status;
        self.content_type = .json;
        if (self.body) |old| self.allocator.free(old);
        self.body = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    }

    pub fn rawJson(self: *Context, status: u16, data: []const u8) !void {
        self.status = status;
        self.content_type = .json;
        if (self.body) |old| self.allocator.free(old);
        self.body = try self.allocator.dupe(u8, data);
    }

    pub fn text(self: *Context, status: u16, data: []const u8) !void {
        self.status = status;
        self.content_type = .plain;
        if (self.body) |old| self.allocator.free(old);
        self.body = try self.allocator.dupe(u8, data);
    }

    pub fn html(self: *Context, status: u16, data: []const u8) !void {
        self.status = status;
        self.content_type = .html;
        if (self.body) |old| self.allocator.free(old);
        self.body = try self.allocator.dupe(u8, data);
    }

    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
        if (self.headers == null) {
            self.headers = std.ArrayList(u8).empty;
        }
        try self.headers.?.print(self.allocator, "{s}: {s}\r\n", .{ key, value });
    }

    pub fn getHeader(self: *Context, key: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.request_data, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, key)) {
                if (line.len > key.len) {
                    return std.mem.trim(u8, line[key.len..], ": \t\r\n");
                }
            }
        }
        return null;
    }

    /// 从请求 path 的 query string 中提取指定参数值。e.g. ctx.query("to")
    pub fn query(self: *Context, name: []const u8) ?[]const u8 {
        const uri_end = if (std.mem.indexOfScalar(u8, self.request_data, ' ')) |sp| sp else self.request_data.len;
        const first_line = self.request_data[0..uri_end];
        const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
        const uri_part = std.mem.trimLeft(u8, first_line[method_end + 1 ..], " ");
        const uri = uri_part[0 .. (std.mem.indexOfScalar(u8, uri_part, ' ') orelse uri_part.len)];

        const q_pos = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
        const qs = uri[q_pos + 1 ..];
        var it = std.mem.splitScalar(u8, qs, '&');
        while (it.next()) |pair| {
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq_pos];
            if (std.mem.eql(u8, key, name)) {
                return pair[eq_pos + 1 ..];
            }
        }
        return null;
    }

    /// 获取 POST/PUT/PATCH 请求体。
    /// 自动从 Content-Length 取长度。无 body 返回空串。
    pub fn requestBody(self: *Context) []const u8 {
        const header_end = std.mem.indexOf(u8, self.request_data, "\r\n\r\n") orelse
            std.mem.indexOf(u8, self.request_data, "\n\n") orelse
            return "";
        const sep: usize = if (self.request_data[header_end] == '\r') @as(usize, 4) else @as(usize, 2);
        const start = header_end + sep;
        if (start >= self.request_data.len) return "";

        const cl = self.getContentLength();
        const end = if (cl > 0) @min(start + cl, self.request_data.len) else self.request_data.len;
        return self.request_data[start..end];
    }

    /// 解析请求头方法（GET/POST/PUT/...）
    pub fn method(self: *Context) []const u8 {
        const eol = std.mem.indexOf(u8, self.request_data, "\r\n") orelse
            std.mem.indexOfScalar(u8, self.request_data, '\n') orelse
            return "";
        const first_sp = std.mem.indexOfScalar(u8, self.request_data[0..eol], ' ') orelse return "";
        return self.request_data[0..first_sp];
    }

    /// 解析 Content-Length（未声明返回 0）
    pub fn getContentLength(self: *Context) usize {
        const val = self.getHeader("Content-Length:") orelse return 0;
        return std.fmt.parseInt(usize, val, 10) catch 0;
    }

    /// 解析 Content-Type，返回 MIME type（不含参数，如 "application/json"）
    pub fn getContentType(self: *Context) []const u8 {
        const raw = self.getHeader("Content-Type:") orelse return "";
        const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
        return std.mem.trim(u8, raw[0..semi], " \t\r\n");
    }

    /// 判断 Content-Type 是否为 JSON
    pub fn isJson(self: *Context) bool {
        const ct = self.getContentType();
        return std.mem.eql(u8, ct, "application/json");
    }

    pub fn clearHeaders(self: *Context) void {
        if (self.headers) |*h| {
            h.clearRetainingCapacity();
        }
    }

    pub fn deinit(self: *Context) void {
        if (self.body) |b| self.allocator.free(b);
        if (self.headers) |*h| h.deinit(self.allocator);
    }
};
