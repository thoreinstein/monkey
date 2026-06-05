const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

closure: *object.Closure,
ip: i64,
base_pointer: usize,

pub fn init(cl: *object.Closure, base_pointer: usize) Self {
    return .{
        .closure = cl,
        .ip = -1,
        .base_pointer = base_pointer,
    };
}

pub fn instructions(self: *const Self) code.Instructions {
    return self.closure.func.instructions;
}
