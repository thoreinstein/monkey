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
                else => return null,
            }
        },
        .expression => |e| {
            switch (e) {
                .integer_literal => |il| return .{ .integer = object.Integer{ .value = il.value } },
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

test "integer expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "5", .expected = 5 },
        .{ .input = "10", .expected = 10 },
    };

    for (tests) |t| {
        const evaluated = try testEval(arena.allocator(), t.input) orelse return error.NoEval;

        try testIntegerObject(evaluated, t.expected);
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
