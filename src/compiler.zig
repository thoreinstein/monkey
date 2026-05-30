const std = @import("std");
const testing = std.testing;

const ByteCode = @import("helpers.zig").ByteCode;
const EmittedInstruction = @import("helpers.zig").EmittedInstruction;

const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const SymbolTable = @import("symbol_table.zig");

const ast = @import("ast.zig");
const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

instructions: std.ArrayList(u8),
constants: std.ArrayList(object.Object),
last_instruction: ?EmittedInstruction,
previous_instruction: ?EmittedInstruction,
symbol_table: *SymbolTable,

pub fn init(allocator: std.mem.Allocator) !Self {
    const st = try allocator.create(SymbolTable);
    st.* = SymbolTable.init(allocator);

    return Self{
        .constants = std.ArrayList(object.Object).empty,
        .instructions = std.ArrayList(u8).empty,
        .last_instruction = null,
        .previous_instruction = null,
        .symbol_table = st,
    };
}

pub fn initWithState(allocator: std.mem.Allocator, s: *SymbolTable, constants: std.ArrayList(object.Object)) !Self {
    var compiler = try init(allocator);

    compiler.symbol_table = s;
    compiler.constants = constants;

    return compiler;
}

pub fn compile(self: *Self, allocator: std.mem.Allocator, node: ast.Node) !void {
    switch (node) {
        .program => |p| for (p.statements.items) |stmt| try self.compile(allocator, .{ .statement = stmt }),
        .expression => |e| {
            switch (e) {
                .identifier_expression => |ie| {
                    const symbol = self.symbol_table.resolve(ie.value) orelse return error.SymbolTableLookupFailed;

                    _ = try self.emit(allocator, .get_global, &.{symbol.index});
                },
                .if_expression => |ie| {
                    try self.compile(allocator, .{ .expression = ie.condition.?.* });

                    const not_truthy_pos = try self.emit(allocator, .jump_not_truthy, &.{9999});

                    try self.compile(allocator, .{ .statement = .{ .block_statement = ie.consequence.? } });

                    if (self.lastInstructionIsPop()) self.removeLastPop();

                    const jump_pos = try self.emit(allocator, .jump, &.{9999});
                    const after_consequence_pos = self.instructions.items.len;

                    try self.changeOperand(allocator, not_truthy_pos, &.{after_consequence_pos});

                    if (ie.alternative == null) {
                        _ = try self.emit(allocator, .null_, &.{});
                    } else {
                        try self.compile(allocator, .{ .statement = .{ .block_statement = ie.alternative.? } });

                        if (self.lastInstructionIsPop()) self.removeLastPop();
                    }

                    const after_alternative_pos = self.instructions.items.len;
                    try self.changeOperand(allocator, jump_pos, &.{after_alternative_pos});
                },
                .prefix_expression => |pe| {
                    try self.compile(allocator, .{ .expression = pe.right.?.* });

                    if (std.mem.eql(u8, "!", pe.operator)) {
                        _ = try self.emit(allocator, .bang, &.{});
                    }

                    if (std.mem.eql(u8, "-", pe.operator)) {
                        _ = try self.emit(allocator, .minus, &.{});
                    }
                },
                .infix_expression => |ie| {
                    if (std.mem.eql(u8, "<", ie.operator)) {
                        try self.compile(allocator, .{ .expression = ie.right.?.* });
                        try self.compile(allocator, .{ .expression = ie.left.?.* });

                        _ = try self.emit(allocator, .greater_than, &.{});

                        return;
                    }

                    try self.compile(allocator, .{ .expression = ie.left.?.* });
                    try self.compile(allocator, .{ .expression = ie.right.?.* });

                    if (std.mem.eql(u8, "+", ie.operator)) {
                        _ = try self.emit(allocator, .add, &.{});
                    }

                    if (std.mem.eql(u8, "-", ie.operator)) {
                        _ = try self.emit(allocator, .sub, &.{});
                    }

                    if (std.mem.eql(u8, "*", ie.operator)) {
                        _ = try self.emit(allocator, .mul, &.{});
                    }

                    if (std.mem.eql(u8, "/", ie.operator)) {
                        _ = try self.emit(allocator, .div, &.{});
                    }

                    if (std.mem.eql(u8, ">", ie.operator)) {
                        _ = try self.emit(allocator, .greater_than, &.{});
                    }

                    if (std.mem.eql(u8, "==", ie.operator)) {
                        _ = try self.emit(allocator, .equal, &.{});
                    }

                    if (std.mem.eql(u8, "!=", ie.operator)) {
                        _ = try self.emit(allocator, .not_equal, &.{});
                    }
                },
                .integer_literal => |il| {
                    const integer = object.Integer{ .value = il.value };
                    const operands = try self.addConstant(allocator, .{ .integer = integer });
                    _ = try self.emit(allocator, .constant, &.{operands});
                },
                .boolean_expression => |be| {
                    if (be.value) {
                        _ = try self.emit(allocator, .true_, &.{});
                    } else {
                        _ = try self.emit(allocator, .false_, &.{});
                    }
                },
                else => {},
            }
        },
        .statement => |s| switch (s) {
            .let_statement => |ls| {
                try self.compile(allocator, .{ .expression = ls.value.?.* });

                const symbol = try self.symbol_table.define(ls.name.value);
                _ = try self.emit(allocator, .set_global, &.{symbol.index});
            },
            .block_statement => |bs| {
                for (bs.statements.items) |stmt| {
                    try self.compile(allocator, .{ .statement = stmt });
                }
            },
            .expression_statement => |es| {
                try self.compile(allocator, .{ .expression = es.expression.?.* });

                _ = try self.emit(allocator, .pop, &.{});
            },
            else => {},
        },
    }
}

pub fn bytecode(self: Self) ByteCode {
    return .{
        .constants = self.constants.items,
        .instructions = self.instructions.items,
    };
}

fn addConstant(self: *Self, allocator: std.mem.Allocator, obj: object.Object) !usize {
    try self.constants.append(allocator, obj);

    return self.constants.items.len - 1;
}

fn emit(self: *Self, allocator: std.mem.Allocator, op: code.Opcode, operands: []const usize) !usize {
    const ins = try code.make(allocator, op, operands);
    const pos = try self.addInstruction(allocator, ins);

    self.setLastInstruction(op, pos);

    return pos;
}

fn addInstruction(self: *Self, allocator: std.mem.Allocator, ins: []const u8) !usize {
    const pos_new_instruction = self.instructions.items.len;
    try self.instructions.appendSlice(allocator, ins);

    return pos_new_instruction;
}

fn setLastInstruction(self: *Self, op: code.Opcode, pos: usize) void {
    const previous = self.last_instruction;
    const last: EmittedInstruction = .{ .opcode = op, .position = pos };

    self.previous_instruction = previous;
    self.last_instruction = last;
}

fn lastInstructionIsPop(self: *const Self) bool {
    return self.last_instruction.?.opcode == .pop;
}

fn removeLastPop(self: *Self) void {
    self.instructions.shrinkRetainingCapacity(self.last_instruction.?.position);

    self.last_instruction = self.previous_instruction;
}

fn replaceLastInstruction(self: *Self, pos: usize, newInstruction: []const u8) void {
    var i: usize = 0;
    while (i < newInstruction.len) : (i += 1) {
        self.instructions.items[pos + i] = newInstruction[i];
    }
}

fn changeOperand(self: *Self, allocator: std.mem.Allocator, op_pos: usize, operand: []const usize) !void {
    const op: code.Opcode = @enumFromInt(self.instructions.items[op_pos]);

    const new_instruction = try code.make(allocator, op, operand);

    self.replaceLastInstruction(op_pos, new_instruction);
}

fn parse(allocator: std.mem.Allocator, input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);
    defer parser.deinit();

    return try parser.parseProgram() orelse error.ParseFailed;
}

const ExpectedConstants = union(enum) {
    integer: i64,
};

const CompilerTestCase = struct {
    input: []const u8,
    expected_constants: []const ExpectedConstants,
    expected_instructions: []const code.Instructions,
};

test "integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "1 + 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .add, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1; 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 - 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .sub, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 * 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .mul, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "2 / 1",
            .expected_constants = &.{ .{ .integer = 2 }, .{ .integer = 1 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .div, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "-1",
            .expected_constants = &.{.{ .integer = 1 }},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .minus, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "true",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "!true",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .bang, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "false",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .false_, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 > 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .greater_than, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 < 2",
            .expected_constants = &.{ .{ .integer = 2 }, .{ .integer = 1 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .greater_than, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 == 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .equal, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "1 != 2",
            .expected_constants = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .not_equal, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "true == false",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .false_, &.{}),
                try code.make(arena.allocator(), .equal, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "true != false",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .false_, &.{}),
                try code.make(arena.allocator(), .not_equal, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "conditionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "if (true) { 10 }; 3333;",
            .expected_constants = &.{ .{ .integer = 10 }, .{ .integer = 3333 } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .jump_not_truthy, &.{10}),
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .jump, &.{11}),
                try code.make(arena.allocator(), .null_, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "if (true) { 10 } else { 20 }; 3333;",
            .expected_constants = &.{
                .{ .integer = 10 },
                .{ .integer = 20 },
                .{ .integer = 3333 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .true_, &.{}),
                try code.make(arena.allocator(), .jump_not_truthy, &.{10}),
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .jump, &.{13}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "global let statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input =
            \\let one = 1;
            \\let two = 2
            ,
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .set_global, &.{1}),
            },
        },
        .{
            .input =
            \\let one = 1;
            \\one;
            ,
            .expected_constants = &.{
                .{ .integer = 1 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let one = 1;
            \\let two = one;
            \\two;
            ,
            .expected_constants = &.{
                .{ .integer = 1 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{1}),
                try code.make(arena.allocator(), .get_global, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

fn runCompilerTests(allocator: std.mem.Allocator, tests: []const CompilerTestCase) !void {
    for (tests) |t| {
        const program = try parse(allocator, t.input);

        var compiler = try init(allocator);
        try compiler.compile(allocator, .{ .program = program });
        const bc = compiler.bytecode();

        try testInstructions(allocator, t.expected_instructions, bc.instructions);
        try testConstants(t.expected_constants, bc.constants);
    }
}

fn testInstructions(allocator: std.mem.Allocator, expected: []const code.Instructions, actual: code.Instructions) !void {
    const concatted = try concatInstructions(allocator, expected);

    try testing.expectEqual(concatted.len, actual.len);

    for (concatted, 0..) |ins, i| {
        try testing.expectEqual(ins, actual[i]);
    }
}

fn concatInstructions(allocator: std.mem.Allocator, slices: []const code.Instructions) !code.Instructions {
    var out = std.ArrayList(u8).empty;

    for (slices) |ins| try out.appendSlice(allocator, ins);

    return out.items;
}

fn testConstants(expected: []const ExpectedConstants, actual: []object.Object) !void {
    try testing.expectEqual(expected.len, actual.len);

    for (expected, 0..) |constant, i| {
        switch (constant) {
            .integer => |v| try testIntegerObject(v, actual[i]),
        }
    }
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    const result = switch (actual) {
        .integer => |i| i,
        else => {
            std.debug.print("object is not Integer. got={s}", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqual(expected, result.value);
}
