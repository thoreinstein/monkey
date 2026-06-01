const std = @import("std");
const testing = std.testing;

pub const Instructions = []const u8;

pub const Opcode = enum(u8) {
    add,
    array,
    bang,
    call,
    constant,
    div,
    equal,
    false_,
    get_builtin,
    get_global,
    get_local,
    greater_than,
    hash,
    index,
    jump,
    jump_not_truthy,
    minus,
    mul,
    not_equal,
    null_,
    pop,
    return_,
    return_value,
    set_global,
    set_local,
    sub,
    true_,
};

pub const Definition = struct {
    name: []const u8,
    operand_widths: []const usize,
};

const Operands = struct {
    operands: []usize,
    bytes_read: usize,
};

pub fn lookup(op: Opcode) Definition {
    switch (op) {
        .add => return .{ .name = "OpAdd", .operand_widths = &.{} },
        .array => return .{ .name = "OpArray", .operand_widths = &.{2} },
        .bang => return .{ .name = "OpBang", .operand_widths = &.{} },
        .call => return .{ .name = "OpCall", .operand_widths = &.{1} },
        .constant => return .{ .name = "OpConstant", .operand_widths = &.{2} },
        .div => return .{ .name = "OpDiv", .operand_widths = &.{} },
        .equal => return .{ .name = "OpEqual", .operand_widths = &.{} },
        .false_ => return .{ .name = "OpFalse", .operand_widths = &.{} },
        .get_builtin => return .{ .name = "OpGetBuiltin", .operand_widths = &.{1} },
        .get_global => return .{ .name = "OpGetGlobal", .operand_widths = &.{2} },
        .get_local => return .{ .name = "OpGetLocal", .operand_widths = &.{1} },
        .greater_than => return .{ .name = "OpGreaterThan", .operand_widths = &.{} },
        .hash => return .{ .name = "OpHash", .operand_widths = &.{2} },
        .index => return .{ .name = "OpIndex", .operand_widths = &.{} },
        .jump => return .{ .name = "OpJump", .operand_widths = &.{2} },
        .jump_not_truthy => return .{ .name = "OpJumpNotTruthy", .operand_widths = &.{2} },
        .minus => return .{ .name = "OpMinus", .operand_widths = &.{} },
        .mul => return .{ .name = "OpMul", .operand_widths = &.{} },
        .not_equal => return .{ .name = "OpNotEqual", .operand_widths = &.{} },
        .null_ => return .{ .name = "OpNull", .operand_widths = &.{} },
        .pop => return .{ .name = "OpPop", .operand_widths = &.{} },
        .return_ => return .{ .name = "OpReturn", .operand_widths = &.{} },
        .return_value => return .{ .name = "OpReturnValue", .operand_widths = &.{} },
        .set_global => return .{ .name = "OpSetGlobal", .operand_widths = &.{2} },
        .set_local => return .{ .name = "OpSetLocal", .operand_widths = &.{1} },
        .sub => return .{ .name = "OpSub", .operand_widths = &.{} },
        .true_ => return .{ .name = "OpTrue", .operand_widths = &.{} },
    }
}

pub fn make(allocator: std.mem.Allocator, op: Opcode, operands: []const usize) ![]const u8 {
    const def = switch (op) {
        inline else => |v| lookup(v),
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
            1 => instruction[offset] = @intCast(o),
            else => {},
        }
        offset += width;
    }

    return instruction;
}

pub fn readOperands(allocator: std.mem.Allocator, def: Definition, ins: Instructions) !Operands {
    var operands = try allocator.alloc(usize, def.operand_widths.len);
    var offset: usize = 0;

    for (def.operand_widths, 0..) |width, i| {
        switch (width) {
            2 => operands[i] = std.mem.readInt(u16, ins[offset..][0..2], .big),
            1 => operands[i] = std.mem.readInt(u8, ins[offset..][0..1], .big),
            else => {},
        }

        offset += width;
    }

    return .{ .operands = operands, .bytes_read = offset };
}

pub fn formatInstructions(allocator: std.mem.Allocator, ins: Instructions) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    const w = &out.writer;

    var i: usize = 0;
    while (i < ins.len) {
        const op = std.enums.fromInt(Opcode, ins[i]) orelse {
            try w.print("ERROR: unknown opcode: {d}\n", .{ins[i]});
            i += 1;
            continue;
        };

        const def = lookup(op);

        const result = try readOperands(allocator, def, ins[i + 1 ..]);
        const instr = try fmtInstructions(allocator, def, result.operands);

        try w.print("{d:0>4} {s}\n", .{ i, instr });

        i += 1 + result.bytes_read;
    }

    return out.toOwnedSlice();
}

fn fmtInstructions(allocator: std.mem.Allocator, def: Definition, operands: []const usize) ![]const u8 {
    const operand_count = def.operand_widths.len;

    if (operands.len != operand_count) {
        return std.fmt.allocPrint(allocator, "ERROR: operand len {d} does not match defined {d}\n", .{ operands.len, operand_count });
    }

    switch (operand_count) {
        0 => return def.name,
        1 => return std.fmt.allocPrint(allocator, "{s} {d}", .{ def.name, operands[0] }),
        else => {},
    }

    return std.fmt.allocPrint(allocator, "ERROR: unhandled operand_count for {s}\n", .{def.name});
}

test "make" {
    const tests = [_]struct {
        op: Opcode,
        operands: []const usize,
        expected: []const u8,
    }{
        .{ .op = .constant, .operands = &.{65534}, .expected = &.{ @intFromEnum(Opcode.constant), 255, 254 } },
        .{ .op = .add, .operands = &.{}, .expected = &.{@intFromEnum(Opcode.add)} },
        .{ .op = .get_local, .operands = &.{255}, .expected = &.{ @intFromEnum(Opcode.get_local), 255 } },
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

test "instructions string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const instructions = [_]Instructions{
        try make(arena.allocator(), .add, &.{}),
        try make(arena.allocator(), .get_local, &.{1}),
        try make(arena.allocator(), .constant, &.{2}),
        try make(arena.allocator(), .constant, &.{65535}),
    };

    const expected =
        \\0000 OpAdd
        \\0001 OpGetLocal 1
        \\0003 OpConstant 2
        \\0006 OpConstant 65535
        \\
    ;

    var concatted = std.ArrayList(u8).empty;

    for (instructions) |ins| try concatted.appendSlice(arena.allocator(), ins);

    const formatted = try formatInstructions(arena.allocator(), concatted.items);

    try testing.expectEqualStrings(expected, formatted);
}

test "read operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        op: Opcode,
        operands: []const usize,
        bytes_read: usize,
    }{
        .{ .op = .constant, .operands = &.{65535}, .bytes_read = 2 },
        .{ .op = .get_local, .operands = &.{255}, .bytes_read = 1 },
    };

    for (tests) |t| {
        const instruction = try make(arena.allocator(), t.op, t.operands);

        const def = lookup(t.op);

        const result = try readOperands(arena.allocator(), def, instruction[1..]);

        try testing.expectEqual(t.bytes_read, result.bytes_read);

        for (t.operands, 0..) |want, i| {
            try testing.expectEqual(want, result.operands[i]);
        }
    }
}
