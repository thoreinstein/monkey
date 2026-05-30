const std = @import("std");
const testing = std.testing;

const ByteCode = @import("helpers.zig").ByteCode;

const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const ast = @import("ast.zig");
const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

instructions: std.ArrayList(u8),
constants: std.ArrayList(object.Object),

pub fn init() Self {
    return Self{
        .constants = std.ArrayList(object.Object).empty,
        .instructions = std.ArrayList(u8).empty,
    };
}

pub fn compile(self: *Self, allocator: std.mem.Allocator, node: ast.Node) !void {
    switch (node) {
        .program => |p| for (p.statements.items) |stmt| try self.compile(allocator, .{ .statement = stmt }),
        .expression => |e| {
            switch (e) {
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

    return pos;
}

fn addInstruction(self: *Self, allocator: std.mem.Allocator, ins: []const u8) !usize {
    const pos_new_instruction = self.instructions.items.len;
    try self.instructions.appendSlice(allocator, ins);

    return pos_new_instruction;
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

fn runCompilerTests(allocator: std.mem.Allocator, tests: []const CompilerTestCase) !void {
    for (tests) |t| {
        const program = try parse(allocator, t.input);

        var compiler = init();
        try compiler.compile(allocator, .{ .program = program });
        const bc = compiler.bytecode();

        try testInstructions(allocator, t.expected_instructions, bc.instructions);
        try testConstants(t.expected_constants, bc.constants);
    }
}

fn testInstructions(allocator: std.mem.Allocator, expected: []const code.Instructions, actual: code.Instructions) !void {
    const concatted = try concatInstructions(allocator, expected);

    try testing.expectEqual(actual.len, concatted.len);

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
