const std = @import("std");
const testing = std.testing;

pub const Instructions = []u8;

pub const Opcode = enum(u8) {
    constant,
};

pub const Definition = struct {
    name: []const u8,
    operand_widths: []const usize,
};

pub fn lookup(op: Opcode) Definition {
    switch (op) {
        .constant => return .{ .name = "OpConstant", .operand_widths = &.{2} },
    }
}

pub fn make(allocator: std.mem.Allocator, op: Opcode, operands: []const usize) ![]const u8 {
    const def = switch (op) {
        .constant => |c| lookup(c),
    };

    var instruction_len: usize = 1;

    for (def.operand_widths) |w| instruction_len += w;

    var instruction = try allocator.alloc(u8, instruction_len);
    instruction[0] = @intFromEnum(op);

    var offset: usize = 1;
    for (operands, 0..) |o, i| {
        const width = def.operand_widths[i];
        switch (width) {
            2 => std.mem.writeInt(u16, instruction[offset..][0..2], @intCast(o), .big),
            else => {},
        }
        offset += width;
    }

    return instruction;
}

test "make" {
    const tests = [_]struct {
        op: Opcode,
        operands: []const usize,
        expected: []const u8,
    }{
        .{ .op = .constant, .operands = &.{65534}, .expected = &.{ @intFromEnum(Opcode.constant), 255, 254 } },
    };

    for (tests) |t| {
        const instruction = try make(testing.allocator, t.op, t.operands);
        defer testing.allocator.free(instruction);

        try testing.expectEqual(t.expected.len, instruction.len);

        for (t.expected, 0..) |_, i| {
            try testing.expectEqual(t.expected[i], instruction[i]);
        }
    }
}
