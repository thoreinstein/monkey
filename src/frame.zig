const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

func: object.CompiledFunction,
ip: i64,

pub fn init(allocator: std.mem.Allocator, func: object.CompiledFunction) !*Self {
    const new = try allocator.create(Self);

    new.* = .{
        .func = func,
        .ip = -1,
    };

    return new;
}

pub fn instructions(self: *const Self) code.Instructions {
    return self.func.instructions;
}
