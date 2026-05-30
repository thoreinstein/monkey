const std = @import("std");
const testing = std.testing;

const Compiler = @import("compiler.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const ByteCode = @import("helpers.zig").ByteCode;

const ast = @import("ast.zig");
const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

const stack_size: usize = 2048;

constants: []object.Object,
instructions: code.Instructions,
stack: []object.Object,
sp: usize,

pub fn init(allocator: std.mem.Allocator, bytecode: ByteCode) !Self {
    return .{
        .constants = bytecode.constants,
        .instructions = bytecode.instructions,
        .stack = try allocator.alloc(object.Object, stack_size),
        .sp = 0,
    };
}

pub fn run(self: *Self) !void {
    var ip: usize = 0;

    while (ip < self.instructions.len) : (ip += 1) {
        const op: code.Opcode = @enumFromInt(self.instructions[ip]);

        switch (op) {
            .constant => {
                const const_index = std.mem.readInt(u16, self.instructions[ip + 1 ..][0..2], .big);
                ip += 2;

                try self.push(self.constants[const_index]);
            },
        }
    }
}

pub fn stackTop(self: Self) ?object.Object {
    if (self.sp == 0) return null;

    return self.stack[self.sp - 1];
}

fn push(self: *Self, o: object.Object) !void {
    if (self.sp >= stack_size) return error.StackOverflow;

    self.stack[self.sp] = o;
    self.sp += 1;
}

const Expected = union(enum) {
    integer: i64,
};

const VMTestCase = struct {
    input: []const u8,
    expected: Expected,
};

test "integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "1", .expected = .{ .integer = 1 } },
        .{ .input = "2", .expected = .{ .integer = 2 } },
        .{ .input = "1 + 2", .expected = .{ .integer = 2 } },
    };

    try runVMTests(arena.allocator(), &tests);
}

fn parse(allocator: std.mem.Allocator, input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);

    return try parser.parseProgram() orelse error.ParseProgramError;
}

fn runVMTests(allocator: std.mem.Allocator, tests: []const VMTestCase) !void {
    for (tests) |t| {
        const program = try parse(allocator, t.input);

        var compiler = Compiler.init();
        try compiler.compile(allocator, .{ .program = program });

        var vm = try init(allocator, compiler.bytecode());

        try vm.run();

        const stack_elem = vm.stackTop() orelse return error.StackTopError;

        try testExpectedObject(t.expected, stack_elem);
    }
}

fn testExpectedObject(expected: Expected, actual: object.Object) !void {
    switch (expected) {
        .integer => |i| try testIntegerObject(i, actual),
    }
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    const int_obj = switch (actual) {
        .integer => |i| i,
        else => {
            std.debug.print("object is not Integer, got={s}", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqual(expected, int_obj.value);
}
