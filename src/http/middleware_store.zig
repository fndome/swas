const std = @import("std");
const Allocator = std.mem.Allocator;
const PathRule = @import("../antpath.zig").PathRule;
const Middleware = @import("types.zig").Middleware;

pub const WildcardEntry = struct {
    rule: PathRule,
    list: std.ArrayList(Middleware),
};

pub const MiddlewareStore = struct {
    has_global: bool,
    global: std.ArrayList(Middleware),
    precise: std.StringHashMap(std.ArrayList(Middleware)),
    wildcard: std.ArrayList(WildcardEntry),

    pub fn deinit(self: *MiddlewareStore, allocator: Allocator) void {
        self.global.deinit(allocator);

        var precise_it = self.precise.iterator();
        while (precise_it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        self.precise.deinit();

        for (self.wildcard.items) |*entry| {
            entry.rule.deinit();
            entry.list.deinit(allocator);
        }
        self.wildcard.deinit(allocator);
    }
};
