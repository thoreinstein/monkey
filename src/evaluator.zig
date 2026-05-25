const std = @import("std");
const testing = std.testing;

const object = @import("object.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const ast = @import("ast.zig");

pub fn eval(node: ast.Node) ?object.Object {
    switch (node) {
        .program => |p| return evalStatements(p.statements),
        .statement => |s| {
            switch (s) {
                .expression_statement => |es| return eval(.{ .expression = es.expression.?.* }),
                .block_statement => |bs| return evalStatements(bs.statements),
                else => return null,
            }
        },
        .expression => |e| {
            switch (e) {
                .integer_literal => |il| return .{ .integer = .{ .value = il.value } },
                .boolean_expression => |be| return .{ .boolean = .{ .value = be.value } },
                .if_expression => |ie| return evalIfExpression(ie),
                .prefix_expression => |pe| {
                    const right = eval(.{ .expression = pe.right.?.* }) orelse return null;

                    return evalPrefixExpression(pe.operator, right);
                },
                .infix_expression => |ie| {
                    const left = eval(.{ .expression = ie.left.?.* }) orelse return null;
                    const right = eval(.{ .expression = ie.right.?.* }) orelse return null;

                    return evalInfixExpression(ie.operator, left, right);
                },
                else => return null,
            }
        },
    }
}

fn evalStatements(stmts: std.ArrayList(ast.Statement)) ?object.Object {
    var result: ?object.Object = null;

    for (stmts.items) |s| result = eval(.{ .statement = s });

    return result;
}

fn evalPrefixExpression(operator: []const u8, right: object.Object) ?object.Object {
    if (std.mem.eql(u8, "!", operator)) return evalBangOperatorExpression(right);
    if (std.mem.eql(u8, "-", operator)) return evalMinusOperatorExpression(right);

    return null;
}

fn evalInfixExpression(operator: []const u8, left: object.Object, right: object.Object) object.Object {
    if (std.mem.eql(u8, object.INTEGER_OBJ, left.kind()) and std.mem.eql(u8, object.INTEGER_OBJ, right.kind())) {
        return evalIntegerIntegerInfixExpression(operator, left, right);
    }

    if (std.mem.eql(u8, "==", operator)) return .{ .boolean = .{ .value = std.meta.eql(left, right) } };
    if (std.mem.eql(u8, "!=", operator)) return .{ .boolean = .{ .value = !std.meta.eql(left, right) } };

    return .{ .null_ = .{} };
}

fn evalBangOperatorExpression(right: object.Object) object.Object {
    return switch (right) {
        .boolean => |b| .{ .boolean = .{ .value = !b.value } },
        .null_ => .{ .boolean = .{ .value = true } },
        else => .{ .boolean = .{ .value = false } },
    };
}

fn evalMinusOperatorExpression(right: object.Object) object.Object {
    if (!std.mem.eql(u8, object.INTEGER_OBJ, right.kind())) return .{ .null_ = .{} };

    return .{ .integer = .{ .value = -right.integer.value } };
}

fn evalIntegerIntegerInfixExpression(operator: []const u8, left: object.Object, right: object.Object) object.Object {
    const leftVal = left.integer.value;
    const rightVal = right.integer.value;

    if (std.mem.eql(u8, "+", operator)) return .{ .integer = .{ .value = leftVal + rightVal } };
    if (std.mem.eql(u8, "-", operator)) return .{ .integer = .{ .value = leftVal - rightVal } };
    if (std.mem.eql(u8, "*", operator)) return .{ .integer = .{ .value = leftVal * rightVal } };
    if (std.mem.eql(u8, "/", operator)) return .{ .integer = .{ .value = @divTrunc(leftVal, rightVal) } };
    if (std.mem.eql(u8, "<", operator)) return .{ .boolean = .{ .value = leftVal < rightVal } };
    if (std.mem.eql(u8, ">", operator)) return .{ .boolean = .{ .value = leftVal > rightVal } };
    if (std.mem.eql(u8, "==", operator)) return .{ .boolean = .{ .value = leftVal == rightVal } };
    if (std.mem.eql(u8, "!=", operator)) return .{ .boolean = .{ .value = leftVal != rightVal } };

    return .{ .null_ = .{} };
}

fn evalIfExpression(exp: ast.IfExpression) ?object.Object {
    const condition = eval(.{ .expression = exp.condition.?.* }) orelse return null;

    if (isTruthy(condition)) return eval(.{ .statement = .{ .block_statement = exp.consequence.? } });
    if (exp.alternative) |a| return eval(.{ .statement = .{ .block_statement = a } });

    return .{ .null_ = .{} };
}

fn isTruthy(obj: object.Object) bool {
    return switch (obj) {
        .null_ => false,
        .boolean => |b| if (b.value) true else false,
        else => true,
    };
}

const Expected = union(enum) {
    int: i64,
    null_: void,
};

test "integer expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "5", .expected = 5 },
        .{ .input = "10", .expected = 10 },
        .{ .input = "-5", .expected = -5 },
        .{ .input = "-10", .expected = -10 },
        .{ .input = "5 + 5 + 5 + 5 - 10", .expected = 10 },
        .{ .input = "2 * 2 * 2 * 2 * 2", .expected = 32 },
        .{ .input = "-50 + 100 + -50", .expected = 0 },
        .{ .input = "5 * 2 + 10", .expected = 20 },
        .{ .input = "5 + 2 * 10", .expected = 25 },
        .{ .input = "20 + 2 * -10", .expected = 0 },
        .{ .input = "50 / 2 * 2 + 10", .expected = 60 },
        .{ .input = "2 * (5 + 10)", .expected = 30 },
        .{ .input = "3 * 3 * 3 + 10", .expected = 37 },
        .{ .input = "3 * (3 * 3) + 10", .expected = 37 },
        .{ .input = "(5 + 10 * 2 + 15 / 3) * 2 + -10", .expected = 50 },
    };

    for (tests, 0..) |t, i| {
        const evaluated = try testEval(arena.allocator(), t.input) orelse return error.NoEval;

        errdefer std.debug.print("test {d} failed\n", .{i});

        try testIntegerObject(evaluated, t.expected);
    }
}

test "boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "true", .expected = true },
        .{ .input = "false", .expected = false },
        .{ .input = "1 < 2", .expected = true },
        .{ .input = "1 > 2", .expected = false },
        .{ .input = "1 < 1", .expected = false },
        .{ .input = "1 > 1", .expected = false },
        .{ .input = "1 == 1", .expected = true },
        .{ .input = "1 != 1", .expected = false },
        .{ .input = "1 == 2", .expected = false },
        .{ .input = "1 != 2", .expected = true },
        .{ .input = "true == true", .expected = true },
        .{ .input = "false == false", .expected = true },
        .{ .input = "true != false", .expected = true },
        .{ .input = "false != true", .expected = true },
        .{ .input = "(1 < 2) == true", .expected = true },
        .{ .input = "(1 < 2) == false", .expected = false },
        .{ .input = "(1 > 2) == true", .expected = false },
        .{ .input = "(1 > 2) == false", .expected = true },
    };

    for (tests, 0..) |t, i| {
        const evaluated = try testEval(arena.allocator(), t.input) orelse return error.NoEval;

        errdefer std.debug.print("test {d} failed\n", .{i});

        try testBooleanObject(evaluated, t.expected);
    }
}

test "bang operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "!true", .expected = false },
        .{ .input = "!false", .expected = true },
        .{ .input = "!5", .expected = false },
        .{ .input = "!!true", .expected = true },
        .{ .input = "!!false", .expected = false },
        .{ .input = "!!5", .expected = true },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input) orelse return error.NoEval;

        try testBooleanObject(evaluated, t.expected);
    }
}

test "if/else expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: Expected,
    }{
        .{ .input = "if (true) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (false) { 10 }", .expected = .null_ },
        .{ .input = "if (1) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 < 2) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 > 2) { 10 }", .expected = .null_ },
        .{ .input = "if (1 > 2) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        .{ .input = "if (1 < 2) { 10 } else { 20 }", .expected = .{ .int = 10 } },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input) orelse return error.NoEval;

        switch (t.expected) {
            .int => |i| try testIntegerObject(evaluated, i),
            .null_ => try testNullObject(evaluated),
        }
    }
}

fn testEval(allocator: std.mem.Allocator, input: []const u8) !?object.Object {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);

    const program = try parser.parseProgram() orelse return null;

    return eval(.{ .program = program });
}

fn testIntegerObject(obj: object.Object, expected: i64) !void {
    const result = switch (obj) {
        .integer => |i| i,
        else => {
            std.debug.print("obj is not Integer. got={s}\n", .{@tagName(obj)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqual(expected, result.value);
}

fn testBooleanObject(obj: object.Object, expected: bool) !void {
    const result = switch (obj) {
        .boolean => |b| b,
        else => {
            std.debug.print("obj is not Boolean. got={s}\n", .{@tagName(obj)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqual(expected, result.value);
}

fn testNullObject(obj: object.Object) !void {
    switch (obj) {
        .null_ => {},
        else => {
            std.debug.print("obj is not Null. got={s}\n", .{@tagName(obj)});
            return error.WrongExpressionType;
        },
    }
}
