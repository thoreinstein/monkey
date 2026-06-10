const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

ins: code.Instructions,
closure: *object.Closure,
ip: usize,
base_pointer: usize,

pub fn init(cl: *object.Closure, base_pointer: usize) Self {
    return .{
        .ins = cl.func.instructions,
        .closure = cl,
        .ip = 0,
        .base_pointer = base_pointer,
    };
}

pub fn instructions(self: *const Self) code.Instructions {
    return self.ins;
}
