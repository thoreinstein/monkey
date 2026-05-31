const std = @import("std");
const testing = std.testing;

const ByteCode = @import("helpers.zig").ByteCode;
const Compiler = @import("compiler.zig");
const Frame = @import("frame.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const ast = @import("ast.zig");
const code = @import("code.zig");
const object = @import("object.zig");

const Self = @This();

const max_frames: usize = 1024;
const stack_size: usize = 2048;
pub const global_size: usize = 65536;

allocator: std.mem.Allocator,
constants: []object.Object,
frames: []*Frame,
frames_index: usize,
globals: []object.Object,
sp: usize,
stack: []object.Object,

pub fn init(allocator: std.mem.Allocator, bytecode: ByteCode) !Self {
    const main_fn: object.CompiledFunction = .{
        .instructions = bytecode.instructions,
    };

    const main_frame = try Frame.init(allocator, main_fn, 0);

    const frames = try allocator.alloc(*Frame, max_frames);
    frames[0] = main_frame;

    return .{
        .allocator = allocator,
        .constants = bytecode.constants,
        .frames = frames,
        .frames_index = 1,
        .globals = try allocator.alloc(object.Object, global_size),
        .sp = 0,
        .stack = try allocator.alloc(object.Object, stack_size),
    };
}

pub fn initWithGlobalStore(allocator: std.mem.Allocator, bytecode: ByteCode, s: []object.Object) !Self {
    var vm = try init(allocator, bytecode);

    vm.globals = s;

    return vm;
}

pub fn run(self: *Self) !void {
    while (self.currentFrame().ip < @as(i64, @intCast(self.currentFrame().instructions().len)) - 1) {
        self.currentFrame().ip += 1;

        const ip: usize = @intCast(self.currentFrame().ip);
        const ins = self.currentFrame().instructions();
        const op: code.Opcode = @enumFromInt(ins[ip]);

        switch (op) {
            .return_value => {
                const rv = self.pop();

                const frame = self.popFrame();
                self.sp = frame.base_pointer - 1;

                try self.push(rv);
            },
            .return_ => {
                const frame = self.popFrame();
                self.sp = frame.base_pointer - 1;

                try self.push(.null_);
            },
            .call => {
                const num_args = std.mem.readInt(u8, ins[ip + 1 ..][0..1], .big);
                self.currentFrame().ip += 1;

                try self.callFunction(num_args);
            },
            .index => {
                const index = self.pop();
                const left = self.pop();

                try self.executeIndexOperation(left, index);
            },
            .hash => {
                const num_elem: usize = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                const hash = try self.buildHash(self.sp - num_elem, self.sp);

                self.sp = self.sp - num_elem;

                try self.push(hash);
            },
            .array => {
                const num_elem: usize = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                const array = try self.buildArray(self.sp - num_elem, self.sp);

                self.sp = self.sp - num_elem;

                try self.push(array);
            },
            .get_global => {
                const global_index = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                try self.push(self.globals[global_index]);
            },
            .get_local => {
                const local_index = std.mem.readInt(u8, ins[ip + 1 ..][0..1], .big);
                self.currentFrame().ip += 1;

                const frame = self.currentFrame();

                try self.push(self.stack[frame.base_pointer + local_index]);
            },
            .set_global => {
                const global_index = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                self.globals[global_index] = self.pop();
            },
            .set_local => {
                const local_index = std.mem.readInt(u8, ins[ip + 1 ..][0..1], .big);
                self.currentFrame().ip += 1;

                const frame = self.currentFrame();

                self.stack[frame.base_pointer + local_index] = self.pop();
            },
            .constant => {
                const const_index = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                try self.push(self.constants[const_index]);
            },
            .jump => {
                const pos: i64 = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip = pos - 1;
            },
            .jump_not_truthy => {
                const pos: i64 = std.mem.readInt(u16, ins[ip + 1 ..][0..2], .big);
                self.currentFrame().ip += 2;

                const condition = self.pop();

                if (!isTruthy(condition)) self.currentFrame().ip = pos - 1;
            },
            .add, .sub, .mul, .div => try self.executeBinaryOperation(op),
            .true_ => try self.push(.{ .boolean = .{ .value = true } }),
            .false_ => try self.push(.{ .boolean = .{ .value = false } }),
            .equal, .not_equal, .greater_than => try self.executeComparison(op),
            .bang => try self.executeBangOperator(),
            .minus => try self.executeMinusOperator(),
            .null_ => try self.push(.null_),
            .pop => _ = self.pop(),
        }
    }
}

pub fn stackTop(self: Self) ?object.Object {
    if (self.sp == 0) return null;

    return self.stack[self.sp - 1];
}

pub fn lastPoppedStackElem(self: *const Self) object.Object {
    return self.stack[self.sp];
}

fn push(self: *Self, o: object.Object) !void {
    if (self.sp >= stack_size) return error.StackOverflow;

    self.stack[self.sp] = o;
    self.sp += 1;
}

fn pop(self: *Self) object.Object {
    const o = self.stack[self.sp - 1];
    self.sp -= 1;

    return o;
}

fn executeBinaryOperation(self: *Self, op: code.Opcode) !void {
    const right = self.pop();
    const left = self.pop();

    const left_kind = left.kind();
    const right_kind = right.kind();

    if (std.mem.eql(u8, object.INTEGER_OBJ, left_kind) and std.mem.eql(u8, object.INTEGER_OBJ, right_kind)) {
        return try self.executeBinaryIntegerOperation(op, left, right);
    }

    if (std.mem.eql(u8, object.STRING_OBJ, left_kind) and std.mem.eql(u8, object.STRING_OBJ, right_kind)) {
        return try self.executeBinaryStringOperation(op, left, right);
    }

    return error.UnsupportedBinaryOperation;
}

fn executeBinaryStringOperation(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    if (op != .add) return error.UnknownStringOperator;

    const left_value = left.string.value;
    const right_value = right.string.value;

    const val = try std.mem.concat(self.allocator, u8, &.{ left_value, right_value });

    try self.push(.{ .string = .{ .value = val } });
}

fn executeBinaryIntegerOperation(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    const left_value = left.integer.value;
    const right_value = right.integer.value;

    var result: i64 = 0;

    switch (op) {
        .add => result = left_value + right_value,
        .sub => result = left_value - right_value,
        .mul => result = left_value * right_value,
        .div => result = @divTrunc(left_value, right_value),
        else => return error.UnknownIntegerOperation,
    }

    try self.push(.{ .integer = .{ .value = result } });
}

fn executeComparison(self: *Self, op: code.Opcode) !void {
    const right = self.pop();
    const left = self.pop();

    if (std.mem.eql(u8, object.INTEGER_OBJ, left.kind()) and std.mem.eql(u8, object.INTEGER_OBJ, right.kind())) {
        try self.executeIntegerComparison(op, left, right);

        return;
    }

    switch (op) {
        .equal => try self.push(.{ .boolean = .{ .value = left.boolean.value == right.boolean.value } }),
        .not_equal => try self.push(.{ .boolean = .{ .value = left.boolean.value != right.boolean.value } }),
        else => {
            std.debug.print("unknown operator: {s}\n", .{code.lookup(op).name});
            return error.UnknowOperator;
        },
    }
}

fn executeIntegerComparison(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    const left_val = left.integer.value;
    const right_val = right.integer.value;

    switch (op) {
        .equal => try self.push(.{ .boolean = .{ .value = left_val == right_val } }),
        .not_equal => try self.push(.{ .boolean = .{ .value = left_val != right_val } }),
        .greater_than => try self.push(.{ .boolean = .{ .value = left_val > right_val } }),
        else => return error.UnknowOperator,
    }
}

fn executeBangOperator(self: *Self) !void {
    const operand = self.pop();

    switch (operand) {
        .boolean => |b| {
            if (b.value) {
                try self.push(.{ .boolean = .{ .value = false } });
            } else {
                try self.push(.{ .boolean = .{ .value = true } });
            }
        },
        .null_ => try self.push(.{ .boolean = .{ .value = true } }),
        else => try self.push(.{ .boolean = .{ .value = false } }),
    }
}

fn executeMinusOperator(self: *Self) !void {
    const operand = self.pop();

    if (std.mem.eql(u8, object.INTEGER_OBJ, operand.kind())) {
        const value = operand.integer.value;

        return try self.push(.{ .integer = .{ .value = -value } });
    }

    return error.UnsupportedObjectForNegation;
}

fn executeIndexOperation(self: *Self, left: object.Object, index: object.Object) !void {
    if (std.mem.eql(u8, object.ARRAY_OBJ, left.kind()) and std.mem.eql(u8, object.INTEGER_OBJ, index.kind())) {
        return self.executeArrayIndex(left, index);
    }

    if (std.mem.eql(u8, object.HASH_OBJ, left.kind())) {
        return self.executeHashIndex(left, index);
    }

    return error.IndexOperatorNotSupported;
}

fn executeArrayIndex(self: *Self, array: object.Object, index: object.Object) !void {
    const array_obj = array.array;
    const i = index.integer.value;
    const max: i64 = @intCast(array_obj.elements.items.len);

    if (i < 0 or i >= max) return try self.push(.{ .null_ = .{} });

    try self.push(array_obj.elements.items[@intCast(i)]);
}

fn executeHashIndex(self: *Self, hash: object.Object, index: object.Object) !void {
    const hash_obj = hash.hash;

    const key = index.hashKey() orelse return error.ObjectNotHashable;

    const pair = hash_obj.pairs.get(key) orelse {
        return try self.push(.{ .null_ = .{} });
    };

    try self.push(pair.value);
}

fn callFunction(self: *Self, num_args: u8) !void {
    const fn_obj = switch (self.stack[self.sp - 1 - num_args]) {
        .compiled_function => |cf| cf,
        else => {
            std.debug.print("calling non function", .{});
            return error.CallingNonFunction;
        },
    };

    if (num_args != fn_obj.num_parameters) return error.WrongNumberOfArguments;

    const frame = try Frame.init(self.allocator, fn_obj, self.sp - num_args);
    self.pushFrame(frame);
    self.sp = frame.base_pointer + fn_obj.num_locals;
}

fn buildArray(self: *Self, start: usize, end: usize) !object.Object {
    var elements = std.ArrayList(object.Object).empty;

    var i = start;
    while (i < end) : (i += 1) {
        try elements.append(self.allocator, self.stack[i]);
    }

    return .{ .array = .{ .elements = elements } };
}

fn buildHash(self: *Self, start: usize, end: usize) !object.Object {
    var hashedPairs = std.AutoHashMap(object.HashKey, object.HashPair).init(self.allocator);

    var i = start;
    while (i < end) : (i += 2) {
        const key = self.stack[i];
        const value = self.stack[i + 1];

        const pair = object.HashPair{ .key = key, .value = value };

        const hashed = key.hashKey() orelse return error.ObjectNotHashable;

        try hashedPairs.put(hashed, pair);
    }

    return .{ .hash = .{ .pairs = hashedPairs } };
}

fn currentFrame(self: *const Self) *Frame {
    return self.frames[self.frames_index - 1];
}

fn pushFrame(self: *Self, f: *Frame) void {
    self.frames[self.frames_index] = f;
    self.frames_index += 1;
}

fn popFrame(self: *Self) *Frame {
    self.frames_index -= 1;

    return self.frames[self.frames_index];
}

fn isTruthy(obj: object.Object) bool {
    return switch (obj) {
        .boolean => |b| b.value,
        .null_ => false,
        else => true,
    };
}

const Expected = union(enum) {
    integer: i64,
    boolean: bool,
    null_: void,
    string: []const u8,
    array: []const i64,
    hash: []const struct { key: object.HashKey, value: i64 },
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
        .{ .input = "1 + 2", .expected = .{ .integer = 3 } },
        .{ .input = "1 - 2", .expected = .{ .integer = -1 } },
        .{ .input = "1 * 2", .expected = .{ .integer = 2 } },
        .{ .input = "4 / 2", .expected = .{ .integer = 2 } },
        .{ .input = "50 / 2 * 2 + 10 - 5", .expected = .{ .integer = 55 } },
        .{ .input = "5 + 5 + 5 + 5 - 10", .expected = .{ .integer = 10 } },
        .{ .input = "2 * 2 * 2 * 2 * 2", .expected = .{ .integer = 32 } },
        .{ .input = "5 * 2 + 10", .expected = .{ .integer = 20 } },
        .{ .input = "5 + 2 * 10", .expected = .{ .integer = 25 } },
        .{ .input = "5 * (2 + 10)", .expected = .{ .integer = 60 } },
        .{ .input = "-5", .expected = .{ .integer = -5 } },
        .{ .input = "-10", .expected = .{ .integer = -10 } },
        .{ .input = "-50 + 100 + -50", .expected = .{ .integer = 0 } },
        .{ .input = "(5 + 10 * 2 + 15 / 3) * 2 + -10", .expected = .{ .integer = 50 } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "true", .expected = .{ .boolean = true } },
        .{ .input = "false", .expected = .{ .boolean = false } },
        .{ .input = "1 < 2", .expected = .{ .boolean = true } },
        .{ .input = "1 > 2", .expected = .{ .boolean = false } },
        .{ .input = "1 < 1", .expected = .{ .boolean = false } },
        .{ .input = "1 > 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 1", .expected = .{ .boolean = true } },
        .{ .input = "1 != 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 2", .expected = .{ .boolean = false } },
        .{ .input = "1 != 2", .expected = .{ .boolean = true } },
        .{ .input = "true == true", .expected = .{ .boolean = true } },
        .{ .input = "false == false", .expected = .{ .boolean = true } },
        .{ .input = "true == false", .expected = .{ .boolean = false } },
        .{ .input = "true != false", .expected = .{ .boolean = true } },
        .{ .input = "false != true", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == true", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == false", .expected = .{ .boolean = false } },
        .{ .input = "(1 > 2) == true", .expected = .{ .boolean = false } },
        .{ .input = "(1 > 2) == false", .expected = .{ .boolean = true } },
        .{ .input = "!true", .expected = .{ .boolean = false } },
        .{ .input = "!false", .expected = .{ .boolean = true } },
        .{ .input = "!5", .expected = .{ .boolean = false } },
        .{ .input = "!!true", .expected = .{ .boolean = true } },
        .{ .input = "!!false", .expected = .{ .boolean = false } },
        .{ .input = "!!5", .expected = .{ .boolean = true } },
        .{ .input = "!(if (false) { 5; })", .expected = .{ .boolean = true } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "conditionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "if (true) { 10 }", .expected = .{ .integer = 10 } },
        .{ .input = "if (true) { 10 } else { 20 }", .expected = .{ .integer = 10 } },
        .{ .input = "if (false) { 10 } else { 20 }", .expected = .{ .integer = 20 } },
        .{ .input = "if (1) { 10 }", .expected = .{ .integer = 10 } },
        .{ .input = "if (1 < 2) { 10 }", .expected = .{ .integer = 10 } },
        .{ .input = "if (1 < 2) { 10 } else { 20 }", .expected = .{ .integer = 10 } },
        .{ .input = "if (1 > 2) { 10 } else { 20 }", .expected = .{ .integer = 20 } },
        .{ .input = "if (1 > 2) { 10 }", .expected = .null_ },
        .{ .input = "if (false) { 10 }", .expected = .null_ },
        .{ .input = "if ((if (false) { 10 })) { 10 } else { 20 }", .expected = .{ .integer = 20 } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "global let statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "let one = 1; one;", .expected = .{ .integer = 1 } },
        .{ .input = "let one = 1; let two = 2; one + two;", .expected = .{ .integer = 3 } },
        .{ .input = "let one = 1; let two = one + one; one + two;", .expected = .{ .integer = 3 } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "\"monkey\"", .expected = .{ .string = "monkey" } },
        .{ .input = "\"mon\" + \"key\"", .expected = .{ .string = "monkey" } },
        .{ .input = "\"mon\" + \"key\" + \"banana\"", .expected = .{ .string = "monkeybanana" } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "[]", .expected = .{ .array = &.{} } },
        .{ .input = "[1, 2, 3]", .expected = .{ .array = &.{ 1, 2, 3 } } },
        .{ .input = "[1 + 2, 3 * 4, 5 + 6]", .expected = .{ .array = &.{ 3, 12, 11 } } },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "hashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "{}", .expected = .{ .hash = &.{} } },
        .{
            .input = "{1: 2, 2: 3}",
            .expected = .{ .hash = &.{
                .{ .key = (object.Integer{ .value = 1 }).hashKey(), .value = 2 },
                .{ .key = (object.Integer{ .value = 2 }).hashKey(), .value = 3 },
            } },
        },
        .{
            .input = "{1 + 1: 2 * 2, 3 + 3: 4 * 4}",
            .expected = .{ .hash = &.{
                .{ .key = (object.Integer{ .value = 2 }).hashKey(), .value = 4 },
                .{ .key = (object.Integer{ .value = 6 }).hashKey(), .value = 16 },
            } },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{ .input = "[1, 2, 3][1]", .expected = .{ .integer = 2 } },
        .{ .input = "[1, 2, 3][0 + 2]", .expected = .{ .integer = 3 } },
        .{ .input = "[[1, 1, 1]][0][0]", .expected = .{ .integer = 1 } },
        .{ .input = "[][0]", .expected = .null_ },
        .{ .input = "[1, 2, 3][99]", .expected = .null_ },
        .{ .input = "[1][-1]", .expected = .null_ },
        .{ .input = "{1: 1, 2: 2}[1]", .expected = .{ .integer = 1 } },
        .{ .input = "{1: 1, 2: 2}[2]", .expected = .{ .integer = 2 } },
        .{ .input = "{1: 1}[0]", .expected = .null_ },
        .{ .input = "{}[0]", .expected = .null_ },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "function call without arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn() { 5 + 10; };
            \\foo();
            ,
            .expected = .{ .integer = 15 },
        },
        .{
            .input =
            \\let one = fn() { 1; };
            \\let two = fn() { 2; };
            \\one() + two();
            ,
            .expected = .{ .integer = 3 },
        },
        .{
            .input =
            \\let a = fn() { 1 };
            \\let b = fn() { a() + 1 };
            \\let c = fn() { b() + 1 };
            \\c();
            ,
            .expected = .{ .integer = 3 },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "function call with return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn() { return 99; 100; };
            \\foo();
            ,
            .expected = .{ .integer = 99 },
        },
        .{
            .input =
            \\let foo = fn() { return 99; return 100; };
            \\foo();
            ,
            .expected = .{ .integer = 99 },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "function call without return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn() { };
            \\foo();
            ,
            .expected = .null_,
        },
        .{
            .input =
            \\let foo = fn() { };
            \\let fooToo = fn() { foo() };
            \\foo();
            \\fooToo();
            ,
            .expected = .null_,
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "first class functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn() { 1; };
            \\let bar = fn() { foo; };
            \\bar()();
            ,
            .expected = .{ .integer = 1 },
        },
        .{
            .input =
            \\let foo = fn() {
            \\  let baz = fn() { 1; };
            \\  baz;
            \\};
            \\foo()();
            ,
            .expected = .{ .integer = 1 },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "functions with bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn() { let one = 1; one };
            \\foo();
            ,
            .expected = .{ .integer = 1 },
        },
        .{
            .input =
            \\let foo = fn() { let one = 1; let two = 2; one + two };
            \\foo();
            ,
            .expected = .{ .integer = 3 },
        },
        .{
            .input =
            \\let foo = fn() { let one = 1; let two = 2; one + two };
            \\let bar = fn() { let three = 3; let four = 4; three + four };
            \\foo() + bar();
            ,
            .expected = .{ .integer = 10 },
        },
        .{
            .input =
            \\let foo = fn() { let foobar = 50; foobar; };
            \\let bar = fn() { let foobar = 100; foobar; };
            \\foo() + bar();
            ,
            .expected = .{ .integer = 150 },
        },
        .{
            .input =
            \\let global = 50
            \\let foo = fn() {
            \\  let num = 1;
            \\  global - num
            \\}
            \\let bar = fn() {
            \\  let num = 2;
            \\  global - num
            \\}
            \\foo() + bar();
            ,
            .expected = .{ .integer = 97 },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "functions with arguments and bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input =
            \\let foo = fn(a) { a; };
            \\foo(4)
            ,
            .expected = .{ .integer = 4 },
        },
        .{
            .input =
            \\let foo = fn(a, b) { a + b; };
            \\foo(1, 2)
            ,
            .expected = .{ .integer = 3 },
        },
        .{
            .input =
            \\let foo = fn(a, b) {
            \\  let c = a + b;
            \\  c;
            \\};
            \\foo(1, 2)
            ,
            .expected = .{ .integer = 3 },
        },
        .{
            .input =
            \\let foo = fn(a, b) {
            \\  let c = a + b;
            \\  c;
            \\};
            \\foo(1, 2) + foo(3, 4);
            ,
            .expected = .{ .integer = 10 },
        },
        .{
            .input =
            \\let foo = fn(a, b) {
            \\  let c = a + b;
            \\  c;
            \\};
            \\let bar = fn() {
            \\  foo(1, 2) + foo(3, 4);
            \\};
            \\bar();
            ,
            .expected = .{ .integer = 10 },
        },
        .{
            .input =
            \\let global = 10;
            \\let foo = fn(a, b) {
            \\  let c = a + b;
            \\  c + global;
            \\};
            \\let bar = fn() {
            \\  foo(1, 2) + foo(3, 4) + global;
            \\};
            \\bar() + global;
            ,
            .expected = .{ .integer = 50 },
        },
    };

    try runVMTests(arena.allocator(), &tests);
}

test "function calls with wrong arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]VMTestCase{
        .{
            .input = "fn() { 1; }(1);",
            .expected = .{ .string = "wrong number of arguments: want=0, got=1" },
        },
        .{
            .input = "fn(a) { a; }();",
            .expected = .{ .string = "wrong number of arguments: want=1, got=0" },
        },
        .{
            .input = "fn(a, b) { a + b; }(1);",
            .expected = .{ .string = "wrong number of arguments: want=2, got=1" },
        },
    };

    for (tests) |t| {
        const progam = try parse(arena.allocator(), t.input);
        var compiler = try Compiler.init(arena.allocator());

        try compiler.compile(arena.allocator(), .{ .program = progam });

        var vm = try init(arena.allocator(), compiler.bytecode());

        try testing.expectError(error.WrongNumberOfArguments, vm.run());
    }
}

fn parse(allocator: std.mem.Allocator, input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);

    return try parser.parseProgram() orelse error.ParseProgramError;
}

fn runVMTests(allocator: std.mem.Allocator, tests: []const VMTestCase) !void {
    for (tests, 0..) |t, i| {
        const program = try parse(allocator, t.input);

        var compiler = try Compiler.init(allocator);
        try compiler.compile(allocator, .{ .program = program });

        var vm = try init(allocator, compiler.bytecode());

        try vm.run();

        const stack_elem = vm.lastPoppedStackElem();

        errdefer std.debug.print("Test {d} failed: {s}\n", .{ i + 1, tests[i].input });

        try testExpectedObject(t.expected, stack_elem);
    }
}

fn testExpectedObject(expected: Expected, actual: object.Object) !void {
    switch (expected) {
        .integer => |i| try testIntegerObject(i, actual),
        .boolean => |b| try testBooleanObject(b, actual),
        .string => |s| try testStringObject(s, actual),
        .null_ => {
            try testing.expect(actual == .null_);
        },
        .array => |a| {
            try testing.expectEqual(a.len, actual.array.elements.items.len);

            for (a, 0..) |exp, i| {
                try testIntegerObject(exp, actual.array.elements.items[i]);
            }
        },
        .hash => |h| {
            const hash_obj = switch (actual) {
                .hash => |ha| ha,
                else => {
                    std.debug.print("object is not Hash, got={s}", .{@tagName(actual)});
                    return error.WrongObjectType;
                },
            };

            try testing.expectEqual(h.len, hash_obj.pairs.count());

            for (h) |pair| {
                const got = hash_obj.pairs.get(pair.key) orelse {
                    std.debug.print("no pair for given key\n", .{});
                    return error.NoPairForKey;
                };

                try testIntegerObject(pair.value, got.value);
            }
        },
    }
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    const int_obj = switch (actual) {
        .integer => |i| i,
        else => {
            std.debug.print("object is not Integer, got={s}\n", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqual(expected, int_obj.value);
}

fn testBooleanObject(expected: bool, actual: object.Object) !void {
    const bool_obj = switch (actual) {
        .boolean => |b| b,
        else => {
            std.debug.print("object is not Boolean, got={s}", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqual(expected, bool_obj.value);
}

fn testStringObject(expected: []const u8, actual: object.Object) !void {
    const str_obj = switch (actual) {
        .string => |s| s,
        else => {
            std.debug.print("object is not String, got={s}", .{@tagName(actual)});
            return error.WrongObjectType;
        },
    };

    try testing.expectEqualStrings(expected, str_obj.value);
}
