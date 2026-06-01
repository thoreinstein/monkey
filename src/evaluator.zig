const std = @import("std");
const testing = std.testing;

const Environment = @import("environment.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const object = @import("object.zig");

pub fn eval(allocator: std.mem.Allocator, node: ast.Node, env: *Environment) error{OutOfMemory}!?object.Object {
    switch (node) {
        .program => |p| return try evalProgram(allocator, p, env),
        .statement => |s| {
            switch (s) {
                .expression_statement => |es| return try eval(allocator, .{ .expression = es.expression.?.* }, env),
                .block_statement => |bs| return try evalBlockStatement(allocator, bs, env),
                .return_statement => |rs| {
                    const value = try eval(allocator, .{ .expression = rs.return_value.?.* }, env) orelse return null;

                    if (isError(value)) return value;

                    const ptr = try allocator.create(object.Object);
                    ptr.* = value;
                    return .{ .return_value = .{ .value = ptr } };
                },
                .let_statement => |ls| {
                    const value = try eval(allocator, .{ .expression = ls.value.?.* }, env) orelse return null;

                    if (isError(value)) return value;

                    _ = try env.set(ls.name.value, value);

                    return null;
                },
            }
        },
        .expression => |e| {
            switch (e) {
                .integer_literal => |il| return .{ .integer = .{ .value = il.value } },
                .string_literal => |s| return .{ .string = .{ .value = s.value } },
                .boolean_expression => |be| return .{ .boolean = .{ .value = be.value } },
                .if_expression => |ie| return try evalIfExpression(allocator, ie, env),
                .identifier_expression => |ie| return try evalIdentifier(allocator, ie, env),
                .hash_literal => |hl| return try evalHashLiteral(allocator, hl, env),
                .prefix_expression => |pe| {
                    const right = try eval(allocator, .{ .expression = pe.right.?.* }, env) orelse return null;

                    if (isError(right)) return right;

                    return evalPrefixExpression(allocator, pe.operator, right);
                },
                .infix_expression => |ie| {
                    const left = try eval(allocator, .{ .expression = ie.left.?.* }, env) orelse return null;

                    if (isError(left)) return left;

                    const right = try eval(allocator, .{ .expression = ie.right.?.* }, env) orelse return null;

                    if (isError(right)) return right;

                    return try evalInfixExpression(allocator, ie.operator, left, right);
                },
                .function_literal => |f| {
                    return .{ .function = .{ .parameters = f.parameters, .body = f.body.?, .env = env } };
                },
                .call_expression => |ce| {
                    const function = try eval(allocator, .{ .expression = ce.function.?.* }, env) orelse return null;

                    if (isError(function)) return function;

                    const args = try evalExpressions(allocator, ce.arguments, env) orelse return null;

                    if (args.items.len == 1 and isError(args.items[0])) return args.items[0];

                    return applyFunction(allocator, function, args);
                },
                .array_literal => |al| {
                    const elements = try evalExpressions(allocator, al.elements, env) orelse return null;

                    if (elements.items.len == 1 and isError(elements.items[0])) return elements.items[0];

                    return .{ .array = .{ .elements = elements } };
                },
                .index_expression => |ie| {
                    const left = try eval(allocator, .{ .expression = ie.left.?.* }, env) orelse return null;

                    if (isError(left)) return left;

                    const index = try eval(allocator, .{ .expression = ie.index.?.* }, env) orelse return null;

                    if (isError(index)) return index;

                    return try evalIndexExpression(allocator, left, index);
                },
            }
        },
    }
}

fn evalProgram(allocator: std.mem.Allocator, program: ast.Program, env: *Environment) !?object.Object {
    var result: ?object.Object = null;

    for (program.statements.items) |stmt| {
        result = try eval(allocator, .{ .statement = stmt }, env);

        if (result) |r| switch (r) {
            .return_value => |rv| return rv.value.*,
            .error_ => return result,
            else => {},
        };
    }

    return result;
}

fn evalStatements(allocator: std.mem.Allocator, stmts: std.ArrayList(ast.Statement), env: *Environment) !?object.Object {
    var result: ?object.Object = null;

    for (stmts.items) |s| {
        result = try eval(allocator, .{ .statement = s }, env);

        if (result) |r| switch (r) {
            .return_value => |rv| return rv.value.*,
            else => {},
        };
    }

    return result;
}

fn evalBlockStatement(allocator: std.mem.Allocator, block: ast.BlockStatement, env: *Environment) !?object.Object {
    var result: ?object.Object = null;

    for (block.statements.items) |stmt| {
        result = try eval(allocator, .{ .statement = stmt }, env);

        if (result) |r| {
            if (std.mem.eql(u8, object.RETURN_VALUE_OBJ, r.kind()) or std.mem.eql(u8, object.ERROR_OBJ, r.kind())) return r;
        }
    }

    return result;
}

fn evalPrefixExpression(allocator: std.mem.Allocator, operator: []const u8, right: object.Object) !?object.Object {
    if (std.mem.eql(u8, "!", operator)) return evalBangOperatorExpression(right);
    if (std.mem.eql(u8, "-", operator)) return try evalMinusOperatorExpression(allocator, right);

    const msg = try std.fmt.allocPrint(allocator, "unknown operator: {s}{s}", .{
        operator,
        right.kind(),
    });

    return .{ .error_ = .{ .message = msg } };
}

fn evalInfixExpression(allocator: std.mem.Allocator, operator: []const u8, left: object.Object, right: object.Object) !object.Object {
    if (std.mem.eql(u8, object.INTEGER_OBJ, left.kind()) and std.mem.eql(u8, object.INTEGER_OBJ, right.kind())) {
        return try evalIntegerIntegerInfixExpression(allocator, operator, left, right);
    }

    if (std.mem.eql(u8, object.STRING_OBJ, left.kind()) and std.mem.eql(u8, object.STRING_OBJ, right.kind())) {
        return try evalStringInfixExpression(allocator, operator, left, right);
    }

    if (std.mem.eql(u8, "==", operator)) return .{ .boolean = .{ .value = std.meta.eql(left, right) } };
    if (std.mem.eql(u8, "!=", operator)) return .{ .boolean = .{ .value = !std.meta.eql(left, right) } };

    if (!std.mem.eql(u8, left.kind(), right.kind())) {
        const msg = try std.fmt.allocPrint(allocator, "type mismatch: {s} {s} {s}", .{
            left.kind(),
            operator,
            right.kind(),
        });

        return .{ .error_ = .{ .message = msg } };
    }

    const msg = try std.fmt.allocPrint(allocator, "unknown operator: {s} {s} {s}", .{
        left.kind(),
        operator,
        right.kind(),
    });

    return .{ .error_ = .{ .message = msg } };
}

fn evalIdentifier(allocator: std.mem.Allocator, node: ast.Identifier, env: *Environment) !object.Object {
    if (env.get(node.value)) |val| return val;

    if (builtins.getByName(node.value)) |b| return .{ .builtin = b };

    const msg = try std.fmt.allocPrint(allocator, "identifier not found: {s}", .{node.value});
    return .{ .error_ = .{ .message = msg } };
}

fn evalHashLiteral(allocator: std.mem.Allocator, node: ast.HashLiteral, env: *Environment) !?object.Object {
    var pairs = std.AutoHashMap(object.HashKey, object.HashPair).init(allocator);

    for (node.pairs.items) |pair| {
        const key = try eval(allocator, .{ .expression = pair.key.* }, env) orelse return null;

        if (isError(key)) return key;

        const hashed = key.hashKey() orelse {
            const msg = try std.fmt.allocPrint(allocator, "unusable as hash key: {s}", .{key.kind()});
            return .{ .error_ = .{ .message = msg } };
        };

        const value = try eval(allocator, .{ .expression = pair.value.* }, env) orelse return null;

        try pairs.put(hashed, .{ .key = key, .value = value });
    }

    return .{
        .hash = .{ .pairs = pairs },
    };
}

fn evalBangOperatorExpression(right: object.Object) object.Object {
    return switch (right) {
        .boolean => |b| .{ .boolean = .{ .value = !b.value } },
        .null_ => .{ .boolean = .{ .value = true } },
        else => .{ .boolean = .{ .value = false } },
    };
}

fn evalMinusOperatorExpression(allocator: std.mem.Allocator, right: object.Object) !object.Object {
    if (!std.mem.eql(u8, object.INTEGER_OBJ, right.kind())) {
        const msg = try std.fmt.allocPrint(allocator, "unknown operator: -{s}", .{
            right.kind(),
        });

        return .{ .error_ = .{ .message = msg } };
    }

    return .{ .integer = .{ .value = -right.integer.value } };
}

fn evalStringInfixExpression(allocator: std.mem.Allocator, operator: []const u8, left: object.Object, right: object.Object) !object.Object {
    if (!std.mem.eql(u8, "+", operator)) {
        const msg = try std.fmt.allocPrint(allocator, "unknown operator: {s} {s} {s}", .{
            left.kind(),
            operator,
            right.kind(),
        });

        return .{ .error_ = .{ .message = msg } };
    }

    const leftVal = left.string.value;
    const rightVal = right.string.value;

    const val = try std.mem.concat(allocator, u8, &.{ leftVal, rightVal });

    return .{ .string = .{ .value = val } };
}

fn evalIntegerIntegerInfixExpression(allocator: std.mem.Allocator, operator: []const u8, left: object.Object, right: object.Object) !object.Object {
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

    const msg = try std.fmt.allocPrint(allocator, "unknown operator: {s} {s} {s}", .{
        left.kind(),
        operator,
        right.kind(),
    });

    return .{ .error_ = .{ .message = msg } };
}

fn evalIfExpression(allocator: std.mem.Allocator, exp: ast.IfExpression, env: *Environment) !?object.Object {
    const condition = try eval(allocator, .{ .expression = exp.condition.?.* }, env) orelse return null;

    if (isError(condition)) return condition;

    if (isTruthy(condition)) return try eval(allocator, .{ .statement = .{ .block_statement = exp.consequence.? } }, env);
    if (exp.alternative) |a| return try eval(allocator, .{ .statement = .{ .block_statement = a } }, env);

    return .{ .null_ = .{} };
}

fn evalExpressions(allocator: std.mem.Allocator, exps: std.ArrayList(*ast.Expression), env: *Environment) !?std.ArrayList(object.Object) {
    var result = std.ArrayList(object.Object).empty;

    for (exps.items) |exp| {
        const evaluated = try eval(allocator, .{ .expression = exp.* }, env) orelse return null;

        if (isError(evaluated)) {
            result.clearRetainingCapacity();
            try result.append(allocator, evaluated);
            return result;
        }

        try result.append(allocator, evaluated);
    }

    return result;
}

fn evalIndexExpression(allocator: std.mem.Allocator, left: object.Object, index: object.Object) !?object.Object {
    if (std.mem.eql(u8, object.ARRAY_OBJ, left.kind()) and std.mem.eql(u8, object.INTEGER_OBJ, index.kind())) {
        return evalArrayIndexExpression(left, index);
    }

    if (std.mem.eql(u8, object.HASH_OBJ, left.kind())) {
        return evalHashIndexExpression(allocator, left, index);
    }

    const msg = try std.fmt.allocPrint(allocator, "index operator not supporrted: {s}", .{left.kind()});
    return .{ .error_ = .{ .message = msg } };
}

fn evalHashIndexExpression(allocator: std.mem.Allocator, hash: object.Object, index: object.Object) !?object.Object {
    const hash_obj = switch (hash) {
        .hash => |h| h,
        else => return null,
    };

    const hashed = index.hashKey() orelse {
        const msg = try std.fmt.allocPrint(allocator, "unusable as hash key: {s}", .{index.kind()});
        return .{ .error_ = .{ .message = msg } };
    };

    const pair = hash_obj.pairs.get(hashed) orelse return .{ .null_ = .{} };

    return pair.value;
}

fn evalArrayIndexExpression(left: object.Object, index: object.Object) !?object.Object {
    const array_obj = left.array;
    const idx = index.integer.value;
    const max: i64 = @intCast(array_obj.elements.items.len);

    if (idx < 0 or idx >= max) return .{ .null_ = .{} };

    return array_obj.elements.items[@intCast(idx)];
}

fn applyFunction(allocator: std.mem.Allocator, func: object.Object, args: std.ArrayList(object.Object)) !?object.Object {
    switch (func) {
        .function => |f| {
            const extendedEnv = try extendFunctionEnv(allocator, f, args);
            const evaluated = try eval(allocator, .{ .statement = .{ .block_statement = f.body } }, extendedEnv) orelse return null;

            return switch (evaluated) {
                .return_value => |rv| rv.value.*,
                else => evaluated,
            };
        },
        .builtin => |b| return b.func(allocator, args.items),
        else => {
            const msg = try std.fmt.allocPrint(allocator, "not a function: {s}", .{func.kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }
}

fn extendFunctionEnv(allocator: std.mem.Allocator, func: object.Function, args: std.ArrayList(object.Object)) !*Environment {
    var env = try allocator.create(Environment);
    env.* = Environment.initEnclosedEnvironment(allocator, func.env);

    for (func.parameters.items, 0..) |param, i| {
        _ = try env.set(param.value, args.items[i]);
    }

    return env;
}

fn isTruthy(obj: object.Object) bool {
    return switch (obj) {
        .null_ => false,
        .boolean => |b| if (b.value) true else false,
        else => true,
    };
}

fn isError(obj: object.Object) bool {
    return std.mem.eql(u8, object.ERROR_OBJ, obj.kind());
}

const Expected = union(enum) {
    int: i64,
    null_: void,
    error_: []const u8,
};

test "integer expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

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
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        errdefer std.debug.print("test {d} failed\n", .{i});

        try testIntegerObject(evaluated, t.expected);
    }
}

test "boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

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
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        errdefer std.debug.print("test {d} failed\n", .{i});

        try testBooleanObject(evaluated, t.expected);
    }
}

test "bang operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

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
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        try testBooleanObject(evaluated, t.expected);
    }
}

test "if/else expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

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
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        switch (t.expected) {
            .int => |i| try testIntegerObject(evaluated, i),
            .null_ => try testNullObject(evaluated),
            else => return error.WrongExpectedType,
        }
    }
}

test "return statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "return 10;", .expected = 10 },
        .{ .input = "return 10; 9;", .expected = 10 },
        .{ .input = "return 2 * 5; 9;", .expected = 10 },
        .{ .input = "9; return 2 * 5; 9;", .expected = 10 },
        .{
            .input =
            \\if (10 > 1) {
            \\  if (10 > 1) {
            \\    return 10;
            \\  }
            \\
            \\ return 1;
            ,
            .expected = 10,
        },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        try testIntegerObject(evaluated, t.expected);
    }
}

test "error handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "5 + true;", .expected = "type mismatch: INTEGER + BOOLEAN" },
        .{ .input = "5 + true; 5;", .expected = "type mismatch: INTEGER + BOOLEAN" },
        .{ .input = "-true", .expected = "unknown operator: -BOOLEAN" },
        .{ .input = "true + false", .expected = "unknown operator: BOOLEAN + BOOLEAN" },
        .{ .input = "5; true + false; 5", .expected = "unknown operator: BOOLEAN + BOOLEAN" },
        .{ .input = "if (10 > 1) { true + false; }", .expected = "unknown operator: BOOLEAN + BOOLEAN" },
        .{ .input = "foobar", .expected = "identifier not found: foobar" },
        .{ .input = "\"Hello\" - \"World\"", .expected = "unknown operator: STRING - STRING" },
        .{ .input = "{\"name\": \"Monkey\"}[fn(x) { x }]", .expected = "unusable as hash key: FUNCTION" },
        .{ .input =
        \\if (10 > 1) {
        \\  if (10 > 1) {
        \\    return true + false;
        \\  }
        \\
        \\  return 1;
        \\}
        , .expected = "unknown operator: BOOLEAN + BOOLEAN" },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        const err_obj = switch (evaluated) {
            .error_ => |e| e,
            else => {
                std.debug.print("obj is not Error. got={s}\n", .{@tagName(evaluated)});
                return error.WrongExpressionType;
            },
        };

        try testing.expectEqualStrings(t.expected, err_obj.message);
    }
}

test "let statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let a = 5; a;", .expected = 5 },
        .{ .input = "let a = 5 * 5; a;", .expected = 25 },
        .{ .input = "let a = 5; let b = a; b;", .expected = 5 },
        .{ .input = "let a = 5; let b = a; let c = a + b + 5; c;", .expected = 15 },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        try testIntegerObject(evaluated, t.expected);
    }
}

test "functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const input = "fn(x) { x + 2; };";

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    const fun_obj = switch (evaluated) {
        .function => |f| f,
        else => {
            std.debug.print("obj is not Function. got={s}\n", .{@tagName(evaluated)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqual(1, fun_obj.parameters.items.len);

    try fun_obj.parameters.items[0].write(&w);
    try testing.expectEqualStrings("x", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try fun_obj.body.write(&w);
    try testing.expectEqualStrings("(x + 2)", w.buffered());
}

test "function calling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let identity = fn(x) { x; }; identity(5);", .expected = 5 },
        .{ .input = "let identity = fn(x) { return x; }; identity(5);", .expected = 5 },
        .{ .input = "let double = fn(x) { x * 2; }; double(5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5, 5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5 + 5, add(5, 5));", .expected = 20 },
        .{ .input = "fn(x) { x; }(5)", .expected = 5 },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        try testIntegerObject(evaluated, t.expected);
    }
}

test "closures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const input =
        \\let newAdder = fn(x) {
        \\  fn(y) { x + y };
        \\};
        \\
        \\let addTwo = newAdder(2);
        \\addTwo(2);
    ;

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    try testIntegerObject(evaluated, 4);
}

test "string literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const input = "\"Hello World!\"";

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    const str_obj = switch (evaluated) {
        .string => |s| s,
        else => {
            std.debug.print("obj is not String. got={s}\n", .{@tagName(evaluated)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqualStrings("Hello World!", str_obj.value);
}

test "string concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const input = "\"Hello\" + \" \"  + \"World!\"";

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    const str_obj = switch (evaluated) {
        .string => |s| s,
        else => {
            std.debug.print("obj is not String. got={s}\n", .{@tagName(evaluated)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqualStrings("Hello World!", str_obj.value);
}

test "builtin functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: Expected,
    }{
        .{ .input = "len(\"\")", .expected = .{ .int = 0 } },
        .{ .input = "len(\"four\")", .expected = .{ .int = 4 } },
        .{ .input = "len(\"hello world\")", .expected = .{ .int = 11 } },
        .{ .input = "len([1, 2, 3])", .expected = .{ .int = 3 } },
        .{ .input = "len(1)", .expected = .{ .error_ = "argument to `len` not supported, got=INTEGER" } },
        .{ .input = "len(\"one\", \"two\")", .expected = .{ .error_ = "wrong number of arguments. got=2, want=1" } },
        .{ .input = "first([1, 2, 3])", .expected = .{ .int = 1 } },
        .{ .input = "first(1)", .expected = .{ .error_ = "argument to `first` must be ARRAY, got=INTEGER" } },
        .{ .input = "last([1, 2, 3])", .expected = .{ .int = 3 } },
        .{ .input = "last(1)", .expected = .{ .error_ = "argument to `last` must be ARRAY, got=INTEGER" } },
        .{ .input = "rest(1)", .expected = .{ .error_ = "argument to `rest` must be ARRAY, got=INTEGER" } },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        switch (t.expected) {
            .int => |i| try testIntegerObject(evaluated, i),
            .error_ => |e| {
                const err_obj = switch (evaluated) {
                    .error_ => |err| err,
                    else => {
                        std.debug.print("obj is not Error. got={s}", .{@tagName(evaluated)});
                        return error.WrongExpressionType;
                    },
                };

                try testing.expectEqualStrings(e, err_obj.message);
            },
            else => return error.WrongExpectedType,
        }
    }
}

test "array literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const input = "[1, 2 * 2, 3 + 3]";

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    const arr_lit = switch (evaluated) {
        .array => |a| a,
        else => {
            std.debug.print("obj is not Array. got={s}", .{@tagName(evaluated)});
            return error.WrongExpressionType;
        },
    };

    try testIntegerObject(arr_lit.elements.items[0], 1);
    try testIntegerObject(arr_lit.elements.items[1], 4);
    try testIntegerObject(arr_lit.elements.items[2], 6);
}

test "index expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: Expected,
    }{
        .{ .input = "[1, 2, 3][0]", .expected = .{ .int = 1 } },
        .{ .input = "[1, 2, 3][1]", .expected = .{ .int = 2 } },
        .{ .input = "[1, 2, 3][2]", .expected = .{ .int = 3 } },
        .{ .input = "let i = 0; [1][i]", .expected = .{ .int = 1 } },
        .{ .input = "[1, 2, 3][1 + 1]", .expected = .{ .int = 3 } },
        .{ .input = "let myArray = [1, 2, 3]; myArray[2]", .expected = .{ .int = 3 } },
        .{ .input = "let myArray = [1, 2, 3]; myArray[0] + myArray[1] + myArray[2];", .expected = .{ .int = 6 } },
        .{ .input = "let myArray = [1, 2, 3]; let i = myArray[0]; myArray[i]", .expected = .{ .int = 2 } },
        .{ .input = "[1, 2, 3][3]", .expected = .null_ },
        .{ .input = "[1, 2, 3][-1]", .expected = .null_ },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        switch (t.expected) {
            .int => |i| try testIntegerObject(evaluated, i),
            .null_ => try testNullObject(evaluated),
            else => return error.WrongExpectedType,
        }
    }
}

test "hash literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const input =
        \\let two = "two";
        \\{
        \\  "one": 10 - 9,
        \\  two: 1 + 1,
        \\  "thr" + "ee": 6 / 2,
        \\  4: 4,
        \\  true: 5,
        \\ false: 6
        \\}
    ;

    const evaluated = try testEval(arena.allocator(), input, &env) orelse return error.NoEval;

    const expected = [_]struct { key: object.HashKey, value: i64 }{
        .{ .key = (object.String{ .value = "one" }).hashKey(), .value = 1 },
        .{ .key = (object.String{ .value = "two" }).hashKey(), .value = 2 },
        .{ .key = (object.String{ .value = "three" }).hashKey(), .value = 3 },
        .{ .key = (object.Integer{ .value = 4 }).hashKey(), .value = 4 },
        .{ .key = (object.Boolean{ .value = true }).hashKey(), .value = 5 },
        .{ .key = (object.Boolean{ .value = false }).hashKey(), .value = 6 },
    };

    const hash_obj = switch (evaluated) {
        .hash => |h| h,
        else => {
            std.debug.print("obj is not Hash. got={s}\n", .{@tagName(evaluated)});
            return error.WrongExpressionType;
        },
    };

    try testing.expectEqual(@as(usize, 6), hash_obj.pairs.count());

    for (expected) |e| {
        const pair = hash_obj.pairs.get(e.key) orelse {
            std.debug.print("no pair for given key\n", .{});
            return error.NoPair;
        };
        try testIntegerObject(pair.value, e.value);
    }
}

test "hash index expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env = Environment.init(arena.allocator());
    defer env.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: Expected,
    }{
        .{ .input = "{\"foo\": 5}[\"foo\"]", .expected = .{ .int = 5 } },
        .{ .input = "{\"foo\": 5}[\"bar\"]", .expected = .null_ },
        .{ .input = "let key = \"foo\";{\"foo\": 5}[key]", .expected = .{ .int = 5 } },
        .{ .input = "{}[\"foo\"]", .expected = .null_ },
        .{ .input = "{5: 5}[5]", .expected = .{ .int = 5 } },
        .{ .input = "{true: 5}[true]", .expected = .{ .int = 5 } },
        .{ .input = "{false: 5}[false]", .expected = .{ .int = 5 } },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input, &env) orelse return error.NoEval;

        switch (t.expected) {
            .int => |i| try testIntegerObject(evaluated, i),
            .null_ => try testNullObject(evaluated),
            else => return error.WrongExpectedType,
        }
    }
}

fn testEval(allocator: std.mem.Allocator, input: []const u8, env: *Environment) !?object.Object {
    const lexer = Lexer.init(input);
    var parser = try Parser.init(allocator, lexer);

    const program = try parser.parseProgram() orelse return null;

    return try eval(allocator, .{ .program = program }, env);
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
