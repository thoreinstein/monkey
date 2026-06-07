const std = @import("std");

const code = @import("code.zig");
const object = @import("object.zig");

pub const LoopContext = struct {
    loop_start: usize,
    break_positions: std.ArrayList(usize),
};

pub const ByteCode = struct {
    instructions: code.Instructions,
    constants: []object.Object,
};

pub const EmittedInstruction = struct {
    opcode: code.Opcode,
    position: usize,
};

pub const CompilationScope = struct {
    instructions: std.ArrayList(u8),
    last_instruction: ?EmittedInstruction,
    previous_instruction: ?EmittedInstruction,
    loops: std.ArrayList(LoopContext),
};
