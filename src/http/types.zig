const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;

pub const Middleware = *const fn (allocator: Allocator, ctx: *Context) anyerror!bool;

pub const Handler = *const fn (allocator: Allocator, ctx: *Context) anyerror!void;
