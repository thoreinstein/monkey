const std = @import("std");

pub const Object = union(enum) {
    const Self = @This();

    integer: Integer,
    boolean: Boolean,
    null_: Null,

    pub fn kind(self: Self) []const u8 {
        return switch (self) {
            inline else => |s| s.kind(),
        };
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
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
        return "INTEGER";
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
        return "Boolean";
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{}", .{self.value});
    }
};

pub const Null = struct {
    const Self = @This();

    pub fn kind(self: *const Self) []const u8 {
        _ = self;
        return "NULL";
    }

    pub fn inspect(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        _ = allocator;

        return "null";
    }
};
