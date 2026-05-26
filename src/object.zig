const std = @import("std");

const Environment = @import("environment.zig");
const ast = @import("ast.zig");

pub const INTEGER_OBJ = "INTEGER";
pub const BOOLEAN_OBJ = "BOOLEAN";
pub const NULL_OBJ = "NULL";
pub const RETURN_VALUE_OBJ = "RETURN_VALUE";
pub const ERROR_OBJ = "ERROR";
pub const FUNCTION_OBJ = "FUNCTION";

pub const Object = union(enum) {
    const Self = @This();

    integer: Integer,
    boolean: Boolean,
    null_: Null,
    return_value: ReturnValue,
    error_: Error,
    function: Function,

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
