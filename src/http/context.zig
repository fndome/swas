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
