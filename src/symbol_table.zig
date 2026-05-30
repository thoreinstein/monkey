const std = @import("std");
const testing = std.testing;

pub const SymbolScope = enum {
    global,
};

pub const Symbol = struct {
    name: []const u8,
    scope: SymbolScope,
    index: usize,
};

const Self = @This();

store: std.StringHashMap(Symbol),
num_definitions: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .store = std.StringHashMap(Symbol).init(allocator),
    };
}

pub fn define(self: *Self, name: []const u8) !Symbol {
    const owned = try self.store.allocator.dupe(u8, name);

    const symbol: Symbol = .{
        .name = owned,
        .index = self.num_definitions,
        .scope = .global,
    };

    try self.store.put(owned, symbol);

    self.num_definitions += 1;

    return symbol;
}

pub fn resolve(self: *const Self, name: []const u8) ?Symbol {
    return self.store.get(name);
}

test "define" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = init(arena.allocator());

    const a = try global.define("a");

    try testing.expectEqualStrings("a", a.name);
    try testing.expectEqual(SymbolScope.global, a.scope);
    try testing.expectEqual(@as(usize, 0), a.index);

    const b = try global.define("b");

    try testing.expectEqualStrings("b", b.name);
    try testing.expectEqual(SymbolScope.global, b.scope);
    try testing.expectEqual(@as(usize, 1), b.index);
}

test "resolve global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = init(arena.allocator());
    _ = try global.define("a");
    _ = try global.define("b");

    const expected = [_]Symbol{
        .{ .name = "a", .scope = .global, .index = 0 },
        .{ .name = "b", .scope = .global, .index = 1 },
    };

    for (expected) |sym| {
        const result = global.resolve(sym.name) orelse return error.SymbolNotInScope;

        try testing.expectEqualStrings(sym.name, result.name);
        try testing.expectEqual(sym.scope, result.scope);
        try testing.expectEqual(sym.index, result.index);
    }
}
