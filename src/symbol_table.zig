const std = @import("std");
const testing = std.testing;

pub const SymbolScope = enum {
    global,
    local,
    builtin,
    free,
};

pub const Symbol = struct {
    name: []const u8,
    scope: SymbolScope,
    index: usize,
};

const Self = @This();

store: std.StringHashMap(Symbol),
num_definitions: usize = 0,
outer: ?*Self = null,
free_symbols: std.ArrayList(Symbol),

pub fn init(allocator: std.mem.Allocator) !*Self {
    const new = try allocator.create(Self);

    new.* = Self{
        .store = std.StringHashMap(Symbol).init(allocator),
        .free_symbols = std.ArrayList(Symbol).empty,
    };

    return new;
}

pub fn initEnclosed(allocator: std.mem.Allocator, outer: *Self) !*Self {
    var s = try init(allocator);
    s.outer = outer;

    return s;
}

pub fn define(self: *Self, name: []const u8) !Symbol {
    const owned = try self.store.allocator.dupe(u8, name);

    const scope: SymbolScope = if (self.outer == null) .global else .local;

    const symbol: Symbol = .{
        .name = owned,
        .index = self.num_definitions,
        .scope = scope,
    };

    try self.store.put(owned, symbol);

    self.num_definitions += 1;

    return symbol;
}

pub fn resolve(self: *Self, name: []const u8) !?Symbol {
    if (self.store.get(name)) |obj| return obj;

    if (self.outer) |outer| {
        const obj = try outer.resolve(name) orelse return null;

        if (obj.scope == .global or obj.scope == .builtin) return obj;

        return try self.defineFree(obj);
    }

    return error.SymbolNotInScope;
}

pub fn defineBuiltin(self: *Self, index: usize, name: []const u8) !Symbol {
    const owned = try self.store.allocator.dupe(u8, name);

    const symbol = Symbol{ .name = owned, .index = index, .scope = .builtin };

    try self.store.put(owned, symbol);

    return symbol;
}

pub fn defineFree(self: *Self, original: Symbol) !Symbol {
    try self.free_symbols.append(self.store.allocator, original);

    const owned = try self.store.allocator.dupe(u8, original.name);

    const symbol = Symbol{ .name = owned, .scope = .free, .index = self.free_symbols.items.len - 1 };

    try self.store.put(owned, symbol);

    return symbol;
}

test "define" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = try init(arena.allocator());

    const a = try global.define("a");

    try testing.expectEqualStrings("a", a.name);
    try testing.expectEqual(SymbolScope.global, a.scope);
    try testing.expectEqual(@as(usize, 0), a.index);

    const b = try global.define("b");

    try testing.expectEqualStrings("b", b.name);
    try testing.expectEqual(SymbolScope.global, b.scope);
    try testing.expectEqual(@as(usize, 1), b.index);

    var first = try initEnclosed(arena.allocator(), global);

    const c = try first.define("c");

    try testing.expectEqualStrings("c", c.name);
    try testing.expectEqual(SymbolScope.local, c.scope);
    try testing.expectEqual(@as(usize, 0), c.index);

    const d = try first.define("d");

    try testing.expectEqualStrings("d", d.name);
    try testing.expectEqual(SymbolScope.local, d.scope);
    try testing.expectEqual(@as(usize, 1), d.index);

    var second = try initEnclosed(arena.allocator(), global);

    const e = try second.define("e");

    try testing.expectEqualStrings("e", e.name);
    try testing.expectEqual(SymbolScope.local, e.scope);
    try testing.expectEqual(@as(usize, 0), e.index);

    const f = try second.define("f");

    try testing.expectEqualStrings("f", f.name);
    try testing.expectEqual(SymbolScope.local, f.scope);
    try testing.expectEqual(@as(usize, 1), f.index);
}

test "resolve global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = try init(arena.allocator());
    _ = try global.define("a");
    _ = try global.define("b");

    const expected = [_]Symbol{
        .{ .name = "a", .scope = .global, .index = 0 },
        .{ .name = "b", .scope = .global, .index = 1 },
    };

    for (expected) |sym| {
        const result = try global.resolve(sym.name) orelse return error.SymbolNotInScope;

        try testing.expectEqualStrings(sym.name, result.name);
        try testing.expectEqual(sym.scope, result.scope);
        try testing.expectEqual(sym.index, result.index);
    }
}

test "resolve local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = try init(arena.allocator());
    _ = try global.define("a");
    _ = try global.define("b");

    var local = try initEnclosed(arena.allocator(), global);
    _ = try local.define("c");
    _ = try local.define("d");

    const expected = [_]Symbol{
        .{ .name = "a", .scope = .global, .index = 0 },
        .{ .name = "b", .scope = .global, .index = 1 },
        .{ .name = "c", .scope = .local, .index = 0 },
        .{ .name = "d", .scope = .local, .index = 1 },
    };

    for (expected) |sym| {
        const result = try local.resolve(sym.name) orelse return error.SymbolNotInScope;

        try testing.expectEqualStrings(sym.name, result.name);
        try testing.expectEqual(sym.scope, result.scope);
        try testing.expectEqual(sym.index, result.index);
    }
}

test "resolve nested local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var global = try init(arena.allocator());
    _ = try global.define("a");
    _ = try global.define("b");

    var first = try initEnclosed(arena.allocator(), global);
    _ = try first.define("c");
    _ = try first.define("d");

    var second = try initEnclosed(arena.allocator(), first);
    _ = try second.define("e");
    _ = try second.define("f");

    const tests = [_]struct {
        table: *Self,
        expected_symbols: []const Symbol,
    }{
        .{
            .table = first,
            .expected_symbols = &.{
                .{ .name = "a", .scope = .global, .index = 0 },
                .{ .name = "b", .scope = .global, .index = 1 },
                .{ .name = "c", .scope = .local, .index = 0 },
                .{ .name = "d", .scope = .local, .index = 1 },
            },
        },
        .{
            .table = second,
            .expected_symbols = &.{
                .{ .name = "a", .scope = .global, .index = 0 },
                .{ .name = "b", .scope = .global, .index = 1 },
                .{ .name = "e", .scope = .local, .index = 0 },
                .{ .name = "f", .scope = .local, .index = 1 },
            },
        },
    };

    for (tests) |t| {
        for (t.expected_symbols) |sym| {
            const result = try t.table.resolve(sym.name) orelse return error.SymbolNotInScope;

            try testing.expectEqualStrings(sym.name, result.name);
            try testing.expectEqual(sym.scope, result.scope);
            try testing.expectEqual(sym.index, result.index);
        }
    }
}

test "define and resolve builtins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const global = try init(arena.allocator());
    const first = try initEnclosed(arena.allocator(), global);
    const second = try initEnclosed(arena.allocator(), first);

    const symbol_tables: []const *Self = &.{ global, first, second };

    const expected: []const Symbol = &.{
        .{ .name = "a", .scope = .builtin, .index = 0 },
        .{ .name = "b", .scope = .builtin, .index = 1 },
        .{ .name = "c", .scope = .builtin, .index = 2 },
        .{ .name = "d", .scope = .builtin, .index = 3 },
    };

    for (expected, 0..) |v, i| {
        _ = try global.defineBuiltin(i, v.name);
    }

    for (symbol_tables) |table| {
        for (expected) |sym| {
            const result = try table.resolve(sym.name) orelse return error.SymbolNotInScope;

            try testing.expectEqualStrings(sym.name, result.name);
            try testing.expectEqual(sym.scope, result.scope);
            try testing.expectEqual(sym.index, result.index);
        }
    }
}

test "resolve free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const global = try init(arena.allocator());
    _ = try global.define("a");
    _ = try global.define("b");

    const first = try initEnclosed(arena.allocator(), global);
    _ = try first.define("c");
    _ = try first.define("d");

    const second = try initEnclosed(arena.allocator(), first);
    _ = try second.define("e");
    _ = try second.define("f");

    const tests = [_]struct {
        table: *Self,
        expected_symbols: []const Symbol,
        expected_free_symbols: []const Symbol,
    }{
        .{
            .table = first,
            .expected_symbols = &.{
                .{ .name = "a", .scope = .global, .index = 0 },
                .{ .name = "b", .scope = .global, .index = 1 },
                .{ .name = "c", .scope = .local, .index = 0 },
                .{ .name = "d", .scope = .local, .index = 1 },
            },
            .expected_free_symbols = &.{},
        },
        .{
            .table = second,
            .expected_symbols = &.{
                .{ .name = "a", .scope = .global, .index = 0 },
                .{ .name = "b", .scope = .global, .index = 1 },
                .{ .name = "c", .scope = .free, .index = 0 },
                .{ .name = "d", .scope = .free, .index = 1 },
                .{ .name = "e", .scope = .local, .index = 0 },
                .{ .name = "f", .scope = .local, .index = 1 },
            },
            .expected_free_symbols = &.{
                .{ .name = "c", .scope = .local, .index = 0 },
                .{ .name = "d", .scope = .local, .index = 1 },
            },
        },
    };

    for (tests) |t| {
        for (t.expected_symbols) |sym| {
            const result = try t.table.resolve(sym.name) orelse return error.SymbolNotInScope;

            try testing.expectEqualStrings(sym.name, result.name);
            try testing.expectEqual(sym.scope, result.scope);
            try testing.expectEqual(sym.index, result.index);
        }

        try testing.expectEqual(t.table.free_symbols.items.len, t.expected_free_symbols.len);

        for (t.expected_free_symbols, 0..) |sym, i| {
            const result = t.table.free_symbols.items[i];

            try testing.expectEqualStrings(sym.name, result.name);
            try testing.expectEqual(sym.scope, result.scope);
            try testing.expectEqual(sym.index, result.index);
        }
    }
}

test "resolve unresolvable free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const global = try init(arena.allocator());
    _ = try global.define("a");

    const first = try initEnclosed(arena.allocator(), global);
    _ = try first.define("c");

    const second = try initEnclosed(arena.allocator(), first);
    _ = try second.define("e");
    _ = try second.define("f");

    const expected: []const Symbol = &.{
        .{ .name = "a", .scope = .global, .index = 0 },
        .{ .name = "c", .scope = .free, .index = 0 },
        .{ .name = "e", .scope = .local, .index = 0 },
        .{ .name = "f", .scope = .local, .index = 1 },
    };

    for (expected) |sym| {
        const result = try second.resolve(sym.name) orelse return error.SymbolNotInScope;

        try testing.expectEqualStrings(sym.name, result.name);
        try testing.expectEqual(sym.scope, result.scope);
        try testing.expectEqual(sym.index, result.index);
    }

    const expect_unresolvable: []const []const u8 = &.{ "b", "d" };

    for (expect_unresolvable) |name| {
        try testing.expectError(error.SymbolNotInScope, second.resolve(name));
    }
}
