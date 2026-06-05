const std = @import("std");
const testing = std.testing;

const Environment = @import("environment.zig");

const ast = @import("ast.zig");
const code = @import("code.zig");

pub const INTEGER_OBJ = "INTEGER";
pub const BOOLEAN_OBJ = "BOOLEAN";
pub const NULL_OBJ = "NULL";
pub const RETURN_VALUE_OBJ = "RETURN_VALUE";
pub const ERROR_OBJ = "ERROR";
pub const FUNCTION_OBJ = "FUNCTION";
pub const STRING_OBJ = "STRING";
pub const BUILTIN_OBJ = "BUILTIN";
pub const ARRAY_OBJ = "ARRAY";
pub const HASH_OBJ = "HASH";
pub const COMPILED_FUNCTION_OBJ = "COMPILED_FUNCTION_OBJ";
pub const CLOSURE_OBJ = "CLOSURE";

const BuiltinFunction = *const fn (allocator: std.mem.Allocator, args: []Object) error{OutOfMemory}!?Object;

pub const ObjectType = enum {
    integer,
    boolean,
    string,
};

pub const Object = union(enum) {
    const Self = @This();

    array: *Array,
    boolean: Boolean,
    builtin: Builtin,
    compiled_function: *CompiledFunction,
    error_: Error,
    function: *Function,
    hash: *Hash,
    integer: Integer,
    null_: Null,
    return_value: ReturnValue,
    string: String,
    closure: *Closure,

    pub fn kind(self: Self) []const u8 {
        return switch (self) {
            inline else => |s| s.kind(),
        };
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self) {
            inline else => |s| s.inspect(allocator),
        };
    }

    pub fn hashKey(self: Self) ?HashKey {
        return switch (self) {
            .integer => |i| i.hashKey(),
            .boolean => |b| b.hashKey(),
            .string => |s| s.hashKey(),
            else => null,
        };
    }
};

pub const Integer = struct {
    const Self = @This();

    value: i64,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return INTEGER_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{self.value});
    }

    pub fn hashKey(self: Self) HashKey {
        return .{
            .kind = .integer,
            .value = @bitCast(self.value),
        };
    }
};

pub const Boolean = struct {
    const Self = @This();

    value: bool,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return BOOLEAN_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{}", .{self.value});
    }

    pub fn hashKey(self: Self) HashKey {
        const value: u64 = if (self.value) 1 else 0;

        return .{
            .kind = .boolean,
            .value = value,
        };
    }
};

pub const Null = struct {
    const Self = @This();

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return NULL_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        _ = allocator;

        return "null";
    }
};

pub const ReturnValue = struct {
    const Self = @This();

    value: *Object,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return RETURN_VALUE_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return self.value.inspect(allocator);
    }
};

pub const Error = struct {
    const Self = @This();

    message: []const u8,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return ERROR_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "ERROR: {s}", .{self.message});
    }
};

pub const Function = struct {
    const Self = @This();

    parameters: std.ArrayList(ast.Identifier),
    body: ast.BlockStatement,
    env: *Environment,

    pub fn kind(self: Self) []const u8 {
        _ = self;

        return FUNCTION_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) anyerror![]const u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("fn(");
        for (self.parameters.items, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(p.value);
        }
        try w.writeAll(") {\n");
        try self.body.write(w);
        try w.writeAll("\n}");

        return aw.toOwnedSlice();
    }
};

pub const String = struct {
    const Self = @This();

    value: []const u8,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;

        return STRING_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}", .{self.value});
    }

    pub fn hashKey(self: Self) HashKey {
        return .{
            .kind = .string,
            .value = std.hash.Fnv1a_64.hash(self.value),
        };
    }
};

pub const Builtin = struct {
    const Self = @This();

    func: BuiltinFunction,

    pub fn kind(self: *const Self) []const u8 {
        _ = self;

        return BUILTIN_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        _ = allocator;

        return "builtin function";
    }
};

pub const Array = struct {
    const Self = @This();

    elements: std.ArrayList(Object),

    pub fn kind(self: *const Self) []const u8 {
        _ = self;

        return ARRAY_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("[");
        for (self.elements.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            const es = try e.inspect(allocator);
            defer allocator.free(es);
            try w.writeAll(es);
        }
        try w.writeAll("]");

        return aw.toOwnedSlice();
    }
};

pub const HashKey = struct {
    kind: ObjectType,
    value: u64,
};

pub const HashPair = struct {
    key: Object,
    value: Object,
};

pub const Hash = struct {
    const Self = @This();

    pairs: std.AutoHashMap(HashKey, HashPair),

    pub fn kind(self: Self) []const u8 {
        _ = self;

        return HASH_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("{");

        var it = self.pairs.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll(", ");
            first = false;

            const pair = entry.value_ptr.*;

            const ks = try pair.key.inspect(allocator);
            defer allocator.free(ks);
            const vs = try pair.value.inspect(allocator);
            defer allocator.free(vs);

            try w.print("{s}: {s}", .{ ks, vs });
        }

        try w.writeAll("}");

        return aw.toOwnedSlice();
    }
};

pub const CompiledFunction = struct {
    const Self = @This();

    instructions: code.Instructions,
    num_locals: usize = 0,
    num_parameters: usize = 0,

    pub fn kind(self: Self) []const u8 {
        _ = self;

        return COMPILED_FUNCTION_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "CompiledFunction{}", .{self});
    }
};

pub const Closure = struct {
    const Self = @This();

    func: *CompiledFunction,
    free: []Object = &.{},

    pub fn kind(self: Self) []const u8 {
        _ = self;

        return CLOSURE_OBJ;
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Closure[{}]", .{self});
    }
};

test "string hash key" {
    const hello1: String = .{ .value = "Hello World" };
    const hello2: String = .{ .value = "Hello World" };
    const diff1: String = .{ .value = "My name is johnny" };
    const diff2: String = .{ .value = "My name is johnny" };

    try testing.expectEqual(hello1.hashKey().value, hello2.hashKey().value);
    try testing.expectEqual(diff1.hashKey().value, diff2.hashKey().value);
    try testing.expect(hello1.hashKey().value != diff1.hashKey().value);
}

test "integer hash key" {
    const one1: Integer = .{ .value = 1 };
    const one2: Integer = .{ .value = 1 };
    const two1: Integer = .{ .value = 2 };
    const two2: Integer = .{ .value = 2 };

    try testing.expectEqual(one1.hashKey().value, one2.hashKey().value);
    try testing.expectEqual(two1.hashKey().value, two2.hashKey().value);
    try testing.expect(one1.hashKey().value != two1.hashKey().value);
}

test "boolean hash key" {
    const true1: Boolean = .{ .value = true };
    const true2: Boolean = .{ .value = true };
    const false1: Boolean = .{ .value = false };
    const false2: Boolean = .{ .value = false };

    try testing.expectEqual(true1.hashKey().value, true2.hashKey().value);
    try testing.expectEqual(false1.hashKey().value, false2.hashKey().value);
    try testing.expect(true1.hashKey().value != false1.hashKey().value);
}

test "object size" {
    std.debug.print("Object: {d} bytes\n", .{@sizeOf(Object)});
    std.debug.print("  Function: {d}  Hash: {d}  Closure: {d}  Array: {d}\n", .{
        @sizeOf(Function), @sizeOf(Hash), @sizeOf(Closure), @sizeOf(Array),
    });
}
