const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

closure: object.Closure,
ip: i64,
base_pointer: usize,

pub fn init(allocator: std.mem.Allocator, cl: object.Closure, base_pointer: usize) !*Self {
    const new = try allocator.create(Self);

    new.* = .{
        .closure = cl,
        .ip = -1,
        .base_pointer = base_pointer,
    };

    return new;
}

pub fn instructions(self: *const Self) code.Instructions {
    return self.closure.func.instructions;
}
