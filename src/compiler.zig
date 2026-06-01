const std = @import("std");
const testing = std.testing;

const ByteCode = @import("helpers.zig").ByteCode;
const EmittedInstruction = @import("helpers.zig").EmittedInstruction;
const CompilationScope = @import("helpers.zig").CompilationScope;

const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const SymbolTable = @import("symbol_table.zig");

const ast = @import("ast.zig");
const builtins = @import("builtins.zig").builtins;
const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

constants: std.ArrayList(object.Object),
instructions: std.ArrayList(u8),
last_instruction: ?EmittedInstruction,
previous_instruction: ?EmittedInstruction,
scope_index: usize,
scopes: std.ArrayList(CompilationScope),
symbol_table: *SymbolTable,

pub fn init(allocator: std.mem.Allocator) !Self {
    const mainScope: CompilationScope = .{
        .instructions = std.ArrayList(u8).empty,
        .last_instruction = null,
        .previous_instruction = null,
    };

    var scopes = std.ArrayList(CompilationScope).empty;
    try scopes.append(allocator, mainScope);

    var symbol_table = try SymbolTable.init(allocator);

    for (builtins, 0..) |b, i| {
        _ = try symbol_table.defineBuiltin(i, b.name);
    }

    return Self{
        .constants = std.ArrayList(object.Object).empty,
        .instructions = std.ArrayList(u8).empty,
        .last_instruction = null,
        .previous_instruction = null,
        .scope_index = 0,
        .scopes = scopes,
        .symbol_table = symbol_table,
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
                .call_expression => |ce| {
                    try self.compile(allocator, .{ .expression = ce.function.?.* });

                    for (ce.arguments.items) |arg| {
                        try self.compile(allocator, .{ .expression = arg.* });
                    }

                    _ = try self.emit(allocator, .call, &.{ce.arguments.items.len});
                },
                .function_literal => |fl| {
                    try self.enterScope(allocator);

                    for (fl.parameters.items) |p| {
                        _ = try self.symbol_table.define(p.value);
                    }

                    try self.compile(allocator, .{ .statement = .{ .block_statement = fl.body.? } });

                    if (self.lastInstructionIs(.pop)) try self.replaceLastPopWithReturn(allocator);

                    if (!self.lastInstructionIs(.return_value)) {
                        _ = try self.emit(allocator, .return_, &.{});
                    }

                    const num_locals = self.symbol_table.num_definitions;
                    const instructions = try self.leaveScope();

                    const compiledFn: object.CompiledFunction = .{
                        .instructions = instructions,
                        .num_locals = num_locals,
                        .num_parameters = fl.parameters.items.len,
                    };

                    const constant = try self.addConstant(allocator, .{ .compiled_function = compiledFn });

                    _ = try self.emit(allocator, .constant, &.{constant});
                },
                .index_expression => |ie| {
                    try self.compile(allocator, .{ .expression = ie.left.?.* });
                    try self.compile(allocator, .{ .expression = ie.index.?.* });

                    _ = try self.emit(allocator, .index, &.{});
                },
                .hash_literal => |hl| {
                    for (hl.pairs.items) |pair| {
                        try self.compile(allocator, .{ .expression = pair.key.* });
                        try self.compile(allocator, .{ .expression = pair.value.* });
                    }

                    _ = try self.emit(allocator, .hash, &.{hl.pairs.items.len * 2});
                },
                .array_literal => |al| {
                    for (al.elements.items) |el| {
                        try self.compile(allocator, .{ .expression = el.* });
                    }

                    _ = try self.emit(allocator, .array, &.{al.elements.items.len});
                },
                .string_literal => |sl| {
                    const str: object.String = .{ .value = sl.value };

                    const constant = try self.addConstant(allocator, .{ .string = str });

                    _ = try self.emit(allocator, .constant, &.{constant});
                },
                .identifier_expression => |ie| {
                    const symbol = self.symbol_table.resolve(ie.value) orelse return error.SymbolTableLookupFailed;

                    try self.loadSymbols(allocator, symbol);
                },
                .if_expression => |ie| {
                    try self.compile(allocator, .{ .expression = ie.condition.?.* });

                    const not_truthy_pos = try self.emit(allocator, .jump_not_truthy, &.{9999});

                    try self.compile(allocator, .{ .statement = .{ .block_statement = ie.consequence.? } });

                    if (self.lastInstructionIs(.pop)) self.removeLastPop();

                    const jump_pos = try self.emit(allocator, .jump, &.{9999});
                    const after_consequence_pos = self.currentInstructions().len;

                    try self.changeOperand(allocator, not_truthy_pos, &.{after_consequence_pos});

                    if (ie.alternative == null) {
                        _ = try self.emit(allocator, .null_, &.{});
                    } else {
                        try self.compile(allocator, .{ .statement = .{ .block_statement = ie.alternative.? } });

                        if (self.lastInstructionIs(.pop)) self.removeLastPop();
                    }

                    const after_alternative_pos = self.currentInstructions().len;
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
            }
        },
        .statement => |s| switch (s) {
            .return_statement => |rs| {
                try self.compile(allocator, .{ .expression = rs.return_value.?.* });

                _ = try self.emit(allocator, .return_value, &.{});
            },
            .let_statement => |ls| {
                try self.compile(allocator, .{ .expression = ls.value.?.* });

                const symbol = try self.symbol_table.define(ls.name.value);

                if (symbol.scope == .global) {
                    _ = try self.emit(allocator, .set_global, &.{symbol.index});
                } else {
                    _ = try self.emit(allocator, .set_local, &.{symbol.index});
                }
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
        },
    }
}

pub fn bytecode(self: Self) ByteCode {
    return .{
        .constants = self.constants.items,
        .instructions = self.currentInstructions(),
    };
}

fn enterScope(self: *Self, allocator: std.mem.Allocator) !void {
    const scope: CompilationScope = .{
        .instructions = std.ArrayList(u8).empty,
        .last_instruction = null,
        .previous_instruction = null,
    };

    try self.scopes.append(allocator, scope);

    self.scope_index += 1;

    self.symbol_table = try SymbolTable.initEnclosed(allocator, self.symbol_table);
}

fn leaveScope(self: *Self) !code.Instructions {
    const instructions = self.currentInstructions();

    self.scopes.shrinkRetainingCapacity(self.scopes.items.len - 1);
    self.scope_index -= 1;
    self.symbol_table = self.symbol_table.outer orelse return error.UnableToLeaveScope;

    return instructions;
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

fn currentInstructions(self: *const Self) code.Instructions {
    return self.scopes.items[self.scope_index].instructions.items;
}

fn addInstruction(self: *Self, allocator: std.mem.Allocator, ins: []const u8) !usize {
    const pos_new_instruction = self.currentInstructions().len;

    try self.scopes.items[self.scope_index].instructions.appendSlice(allocator, ins);

    return pos_new_instruction;
}

fn setLastInstruction(self: *Self, op: code.Opcode, pos: usize) void {
    const previous = self.scopes.items[self.scope_index].last_instruction;
    const last: EmittedInstruction = .{ .opcode = op, .position = pos };

    self.scopes.items[self.scope_index].previous_instruction = previous;
    self.scopes.items[self.scope_index].last_instruction = last;
}

fn lastInstructionIs(self: *const Self, op: code.Opcode) bool {
    if (self.currentInstructions().len == 0) return false;

    return self.scopes.items[self.scope_index].last_instruction.?.opcode == op;
}

fn removeLastPop(self: *Self) void {
    const scope = &self.scopes.items[self.scope_index];

    scope.instructions.shrinkRetainingCapacity(scope.last_instruction.?.position);
    scope.last_instruction = scope.previous_instruction;
}

fn replaceLastInstruction(self: *Self, pos: usize, newInstruction: []const u8) void {
    var ins = self.scopes.items[self.scope_index].instructions.items;

    var i: usize = 0;
    while (i < newInstruction.len) : (i += 1) {
        ins[pos + i] = newInstruction[i];
    }
}

fn replaceLastPopWithReturn(self: *Self, allocator: std.mem.Allocator) !void {
    const last_pos = self.scopes.items[self.scope_index].last_instruction.?.position;

    const ins = try code.make(allocator, .return_value, &.{});
    self.replaceLastInstruction(last_pos, ins);

    self.scopes.items[self.scope_index].last_instruction.?.opcode = .return_value;
}

fn changeOperand(self: *Self, allocator: std.mem.Allocator, op_pos: usize, operand: []const usize) !void {
    const op: code.Opcode = @enumFromInt(self.scopes.items[self.scope_index].instructions.items[op_pos]);

    const new_instruction = try code.make(allocator, op, operand);

    self.replaceLastInstruction(op_pos, new_instruction);
}

fn loadSymbols(self: *Self, allocator: std.mem.Allocator, s: SymbolTable.Symbol) !void {
    switch (s.scope) {
        .global => _ = try self.emit(allocator, .get_global, &.{s.index}),
        .local => _ = try self.emit(allocator, .get_local, &.{s.index}),
        .builtin => _ = try self.emit(allocator, .get_builtin, &.{s.index}),
    }
}

fn parse(allocator: std.mem.Allocator, input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);
    defer parser.deinit();

    return try parser.parseProgram() orelse error.ParseFailed;
}

const ExpectedConstants = union(enum) {
    integer: i64,
    string: []const u8,
    instructions: []const code.Instructions,
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

test "strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "\"monkey\"",
            .expected_constants = &.{.{ .string = "monkey" }},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "\"mon\" + \"key\"",
            .expected_constants = &.{ .{ .string = "mon" }, .{ .string = "key" } },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .add, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "[]",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .array, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "[1, 2, 3]",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .array, &.{3}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "[1 + 2, 3 - 4, 5 * 6]",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
                .{ .integer = 4 },
                .{ .integer = 5 },
                .{ .integer = 6 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .add, &.{}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .sub, &.{}),
                try code.make(arena.allocator(), .constant, &.{4}),
                try code.make(arena.allocator(), .constant, &.{5}),
                try code.make(arena.allocator(), .mul, &.{}),
                try code.make(arena.allocator(), .array, &.{3}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "hashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "{}",
            .expected_constants = &.{},
            .expected_instructions = &.{
                try code.make(arena.allocator(), .hash, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "{1: 2, 3: 4, 5: 6}",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
                .{ .integer = 4 },
                .{ .integer = 5 },
                .{ .integer = 6 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .constant, &.{4}),
                try code.make(arena.allocator(), .constant, &.{5}),
                try code.make(arena.allocator(), .hash, &.{6}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "{1: 2 + 3, 4: 5 * 6}",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
                .{ .integer = 4 },
                .{ .integer = 5 },
                .{ .integer = 6 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .add, &.{}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .constant, &.{4}),
                try code.make(arena.allocator(), .constant, &.{5}),
                try code.make(arena.allocator(), .mul, &.{}),
                try code.make(arena.allocator(), .hash, &.{4}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "[1, 2, 3][1 + 1]",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
                .{ .integer = 1 },
                .{ .integer = 1 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .array, &.{3}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .constant, &.{4}),
                try code.make(arena.allocator(), .add, &.{}),
                try code.make(arena.allocator(), .index, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "{1: 2}[2 - 1]",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 2 },
                .{ .integer = 1 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .hash, &.{2}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .sub, &.{}),
                try code.make(arena.allocator(), .index, &.{}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "fn() { return 5 + 10 }",
            .expected_constants = &.{
                .{ .integer = 5 },
                .{ .integer = 10 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .constant, &.{1}),
                    try code.make(arena.allocator(), .add, &.{}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "fn() { 5 + 10 }",
            .expected_constants = &.{
                .{ .integer = 5 },
                .{ .integer = 10 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .constant, &.{1}),
                    try code.make(arena.allocator(), .add, &.{}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "fn() { 1; 2 }",
            .expected_constants = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .pop, &.{}),
                    try code.make(arena.allocator(), .constant, &.{1}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "fn() { }",
            .expected_constants = &.{
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .return_, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "function calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input = "fn() { 24 }()",
            .expected_constants = &.{
                .{ .integer = 24 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .call, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let noArg = fn() { 24 };
            \\noArg();
            ,
            .expected_constants = &.{
                .{ .integer = 24 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .call, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let oneArg = fn(a) { };
            \\oneArg(24);
            ,
            .expected_constants = &.{
                .{
                    .instructions = &.{
                        try code.make(arena.allocator(), .return_, &.{}),
                    },
                },
                .{ .integer = 24 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .call, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let manyArg = fn(a, b, c) { };
            \\manyArg(24, 25, 26);
            ,
            .expected_constants = &.{
                .{
                    .instructions = &.{
                        try code.make(arena.allocator(), .return_, &.{}),
                    },
                },
                .{ .integer = 24 },
                .{ .integer = 25 },
                .{ .integer = 26 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .call, &.{3}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let oneArg = fn(a) { a };
            \\oneArg(24);
            ,
            .expected_constants = &.{
                .{
                    .instructions = &.{
                        try code.make(arena.allocator(), .get_local, &.{0}),
                        try code.make(arena.allocator(), .return_value, &.{}),
                    },
                },
                .{ .integer = 24 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .call, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\let manyArg = fn(a, b, c) { a; b; c; };
            \\manyArg(24, 25, 26);
            ,
            .expected_constants = &.{
                .{
                    .instructions = &.{
                        try code.make(arena.allocator(), .get_local, &.{0}),
                        try code.make(arena.allocator(), .pop, &.{}),
                        try code.make(arena.allocator(), .get_local, &.{1}),
                        try code.make(arena.allocator(), .pop, &.{}),
                        try code.make(arena.allocator(), .get_local, &.{2}),
                        try code.make(arena.allocator(), .return_value, &.{}),
                    },
                },
                .{ .integer = 24 },
                .{ .integer = 25 },
                .{ .integer = 26 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .get_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .constant, &.{3}),
                try code.make(arena.allocator(), .call, &.{3}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "builtins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input =
            \\len([]);
            \\push([], 1);
            ,
            .expected_constants = &.{
                .{ .integer = 1 },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .get_builtin, &.{0}),
                try code.make(arena.allocator(), .array, &.{0}),
                try code.make(arena.allocator(), .call, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
                try code.make(arena.allocator(), .get_builtin, &.{5}),
                try code.make(arena.allocator(), .array, &.{0}),
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .call, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input = "fn() { len([]) }",
            .expected_constants = &.{
                .{
                    .instructions = &.{
                        try code.make(arena.allocator(), .get_builtin, &.{0}),
                        try code.make(arena.allocator(), .array, &.{0}),
                        try code.make(arena.allocator(), .call, &.{1}),
                        try code.make(arena.allocator(), .return_value, &.{}),
                    },
                },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "let statement scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]CompilerTestCase{
        .{
            .input =
            \\let num = 55;
            \\fn() { num }
            ,
            .expected_constants = &.{
                .{ .integer = 55 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .get_global, &.{0}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{0}),
                try code.make(arena.allocator(), .set_global, &.{0}),
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\fn() {
            \\  let num = 55;
            \\  num
            \\}
            ,
            .expected_constants = &.{
                .{ .integer = 55 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .set_local, &.{0}),
                    try code.make(arena.allocator(), .get_local, &.{0}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{1}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
        .{
            .input =
            \\fn() {
            \\  let a = 55;
            \\  let b = 77;
            \\  a + b
            \\}
            ,
            .expected_constants = &.{
                .{ .integer = 55 },
                .{ .integer = 77 },
                .{ .instructions = &.{
                    try code.make(arena.allocator(), .constant, &.{0}),
                    try code.make(arena.allocator(), .set_local, &.{0}),
                    try code.make(arena.allocator(), .constant, &.{1}),
                    try code.make(arena.allocator(), .set_local, &.{1}),
                    try code.make(arena.allocator(), .get_local, &.{0}),
                    try code.make(arena.allocator(), .get_local, &.{1}),
                    try code.make(arena.allocator(), .add, &.{}),
                    try code.make(arena.allocator(), .return_value, &.{}),
                } },
            },
            .expected_instructions = &.{
                try code.make(arena.allocator(), .constant, &.{2}),
                try code.make(arena.allocator(), .pop, &.{}),
            },
        },
    };

    try runCompilerTests(arena.allocator(), &tests);
}

test "compiler scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var compiler = try init(arena.allocator());
    try testing.expectEqual(@as(usize, 0), compiler.scope_index);
    const global = compiler.symbol_table;

    _ = try compiler.emit(arena.allocator(), .mul, &.{});

    try compiler.enterScope(arena.allocator());
    try testing.expectEqual(@as(usize, 1), compiler.scope_index);

    _ = try compiler.emit(arena.allocator(), .sub, &.{});

    try testing.expectEqual(@as(usize, 1), compiler.scopes.items[compiler.scope_index].instructions.items.len);

    const last = compiler.scopes.items[compiler.scope_index].last_instruction;
    try testing.expectEqual(code.Opcode.sub, last.?.opcode);

    try testing.expect(std.meta.eql(compiler.symbol_table.outer, global));

    _ = try compiler.leaveScope();
    try testing.expectEqual(@as(usize, 0), compiler.scope_index);

    try testing.expect(std.meta.eql(compiler.symbol_table, global));

    try testing.expectEqual(null, compiler.symbol_table.outer);

    _ = try compiler.emit(arena.allocator(), .add, &.{});
    try testing.expectEqual(@as(usize, 2), compiler.scopes.items[compiler.scope_index].instructions.items.len);

    const add = compiler.scopes.items[compiler.scope_index].last_instruction;
    try testing.expectEqual(code.Opcode.add, add.?.opcode);

    const previous = compiler.scopes.items[compiler.scope_index].previous_instruction;
    try testing.expectEqual(code.Opcode.mul, previous.?.opcode);
}

fn runCompilerTests(allocator: std.mem.Allocator, tests: []const CompilerTestCase) !void {
    for (tests, 0..) |t, i| {
        const program = try parse(allocator, t.input);

        var compiler = try init(allocator);
        try compiler.compile(allocator, .{ .program = program });
        const bc = compiler.bytecode();

        errdefer std.debug.print("Test {d} failed: {s}\n", .{ i, tests[i].input });

        try testInstructions(allocator, t.expected_instructions, bc.instructions);
        try testConstants(allocator, t.expected_constants, bc.constants);
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

fn testConstants(allocator: std.mem.Allocator, expected: []const ExpectedConstants, actual: []object.Object) !void {
    try testing.expectEqual(expected.len, actual.len);

    for (expected, 0..) |constant, i| {
        switch (constant) {
            .integer => |v| try testIntegerObject(v, actual[i]),
            .string => |v| try testStringObject(v, actual[i]),
            .instructions => |v| {
                const fn_obj = switch (actual[i]) {
                    .compiled_function => |cf| cf,
                    else => {
                        std.debug.print("constant is not CompiledFunction. got={s}\n", .{@tagName(actual[i])});
                        return error.WrongObjectType;
                    },
                };

                try testInstructions(allocator, v, fn_obj.instructions);
            },
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

fn testStringObject(expected: []const u8, actual: object.Object) !void {
    const result = switch (actual) {
        .string => |s| s,
        else => {
            std.debug.print("object is not String. got={s}", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqualStrings(expected, result.value);
}
