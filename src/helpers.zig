const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

pub const ByteCode = struct {
    instructions: code.Instructions,
    constants: []object.Object,
};
