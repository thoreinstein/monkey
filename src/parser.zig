const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");
const token = @import("token.zig");

const PrefixParseFn = *const fn (*Self) anyerror!?*ast.Expression;
const InfixParseFn = *const fn (*Self, *ast.Expression) anyerror!?ast.Expression;

const Precedence = enum(u8) {
    lowest = 1,
    equals,
    less_greater,
    sum,
    product,
    prefix,
    call,
};

const Self = @This();

allocator: std.mem.Allocator,
lexer: Lexer,

prefix_parse_fns: std.AutoHashMap(token.TokenKind, PrefixParseFn),
infix_parse_fns: std.AutoHashMap(token.TokenKind, InfixParseFn),

current_token: token.Token = undefined,
errors_: std.ArrayList([]const u8) = .empty,
peek_token: token.Token = undefined,

pub fn init(allocator: std.mem.Allocator, lexer: Lexer) !Self {
    var parser = Self{
        .allocator = allocator,
        .lexer = lexer,
        .prefix_parse_fns = std.AutoHashMap(token.TokenKind, PrefixParseFn).init(allocator),
        .infix_parse_fns = std.AutoHashMap(token.TokenKind, InfixParseFn).init(allocator),
    };

    try parser.registerPrefix(.ident, Self.parseIdentifier);
    try parser.registerPrefix(.int, Self.parseIntegerLiteral);
    try parser.registerPrefix(.bang, Self.parsePrefixExpression);
    try parser.registerPrefix(.minus, Self.parsePrefixExpression);
    try parser.registerPrefix(.true_, Self.parseBoolean);
    try parser.registerPrefix(.false_, Self.parseBoolean);
    try parser.registerPrefix(.lparen, Self.parseGroupedExpression);

    try parser.registerInfix(.plus, Self.parseInfixExpression);
    try parser.registerInfix(.minus, Self.parseInfixExpression);
    try parser.registerInfix(.slash, Self.parseInfixExpression);
    try parser.registerInfix(.asterisk, Self.parseInfixExpression);
    try parser.registerInfix(.eq, Self.parseInfixExpression);
    try parser.registerInfix(.not_eq, Self.parseInfixExpression);
    try parser.registerInfix(.lt, Self.parseInfixExpression);
    try parser.registerInfix(.gt, Self.parseInfixExpression);

    parser.nextToken();
    parser.nextToken();

    return parser;
}

pub fn deinit(self: *Self) void {
    for (self.errors_.items) |msg| self.allocator.free(msg);
    self.errors_.deinit(self.allocator);
    self.prefix_parse_fns.deinit();
    self.infix_parse_fns.deinit();
}

pub fn parseProgram(self: *Self) !?ast.Program {
    var program = ast.Program{
        .statements = .empty,
    };

    while (!self.currentTokenIs(.eof)) {
        const statement = try self.parseStatement();

        if (statement) |s| {
            try program.statements.append(self.allocator, s);
        }

        self.nextToken();
    }

    return program;
}

pub fn errors(self: *const Self) std.ArrayList([]const u8) {
    return self.errors_;
}

fn parseStatement(self: *Self) !?ast.Statement {
    switch (self.current_token.kind) {
        .let => {
            const let = try self.parseLetStatement() orelse return null;

            return .{ .let_statement = let };
        },
        .return_ => {
            const ret = try self.parseReturnStatement() orelse return null;

            return .{ .return_statement = ret };
        },
        else => {
            const exp = try self.parseExpressionStatement() orelse return null;

            return .{ .expression_statement = exp };
        },
    }
}

fn parseLetStatement(self: *Self) !?ast.LetStatement {
    var statement = ast.LetStatement{
        .token = self.current_token,
    };

    if (!(try self.expectPeek(.ident))) return null;

    statement.name = ast.Identifier{ .token = self.current_token, .value = self.current_token.literal };

    if (!(try self.expectPeek(.assign))) return null;

    //TODO: We're skipping the expressoins until we encounter a semicolon
    while (!self.currentTokenIs(.semicolon)) self.nextToken();

    return statement;
}

fn parseReturnStatement(self: *Self) !?ast.ReturnStatement {
    const statement = ast.ReturnStatement{
        .token = self.current_token,
    };

    self.nextToken();

    while (!self.currentTokenIs(.semicolon)) self.nextToken();

    return statement;
}

fn parseExpressionStatement(self: *Self) !?ast.ExpressionStatement {
    var statement = ast.ExpressionStatement{
        .token = self.current_token,
    };

    statement.expression = try self.parseExpression(.lowest) orelse return null;

    if (self.peekTokenIs(.semicolon)) self.nextToken();

    return statement;
}

fn parseExpression(self: *Self, precedence: Precedence) !?*ast.Expression {
    const prefix = self.prefix_parse_fns.get(self.current_token.kind) orelse {
        try self.noPrefixParseFnError(self.current_token.kind);
        return null;
    };

    const left_value = try prefix(self) orelse return null;
    var left_exp = try self.allocator.create(ast.Expression);
    left_exp = left_value;

    while (!self.peekTokenIs(.semicolon) and @intFromEnum(precedence) < @intFromEnum(self.peekPrecedence())) {
        const infix = self.infix_parse_fns.get(self.peek_token.kind) orelse return left_exp;
        self.nextToken();

        const new_value = (try infix(self, left_exp)) orelse return left_exp;
        const new_exp = try self.allocator.create(ast.Expression);
        new_exp.* = new_value;
        left_exp = new_exp;
    }

    return left_exp;
}

fn parsePrefixExpression(self: *Self) !?*ast.Expression {
    var expression = ast.PrefixExpression{
        .token = self.current_token,
        .operator = self.current_token.literal,
    };

    self.nextToken();

    expression.right = (try self.parseExpression(.prefix)) orelse return null;

    const new = try self.allocator.create(ast.Expression);

    new.* = ast.Expression{
        .prefix_expression = expression,
    };

    return new;
}

fn parseInfixExpression(self: *Self, left: *ast.Expression) !?ast.Expression {
    var expression = ast.InfixExpression{
        .token = self.current_token,
        .operator = self.current_token.literal,
        .left = left,
    };

    const precedence = self.currentPrecedence();

    self.nextToken();

    expression.right = try self.parseExpression(precedence) orelse return null;

    return .{
        .infix_expression = expression,
    };
}

fn parseIdentifier(self: *const Self) !?*ast.Expression {
    const new = try self.allocator.create(ast.Expression);

    new.* = .{ .identifier_expression = .{
        .token = self.current_token,
        .value = self.current_token.literal,
    } };

    return new;
}

fn parseIntegerLiteral(self: *Self) !?*ast.Expression {
    var literal = ast.IntegerLiteral{
        .token = self.current_token,
    };

    const value = std.fmt.parseInt(i64, self.current_token.literal, 0) catch {
        const msg = try std.fmt.allocPrint(self.allocator, "could not parse {s} as integer.", .{self.current_token.literal});

        try self.errors_.append(self.allocator, msg);

        return null;
    };

    literal.value = value;

    const new = try self.allocator.create(ast.Expression);

    new.* = .{
        .integer_literal = literal,
    };

    return new;
}

fn parseBoolean(self: *const Self) !?*ast.Expression {
    const new = try self.allocator.create(ast.Expression);

    new.* = .{ .boolean_expression = .{
        .token = self.current_token,
        .value = self.currentTokenIs(.true_),
    } };

    return new;
}

fn parseGroupedExpression(self: *Self) !?*ast.Expression {
    self.nextToken();

    const exp = self.parseExpression(.lowest);

    if (!(try self.expectPeek(.rparen))) return null;

    return exp;
}

fn currentTokenIs(self: *const Self, kind: token.TokenKind) bool {
    return self.current_token.kind == kind;
}

fn peekTokenIs(self: *const Self, kind: token.TokenKind) bool {
    return self.peek_token.kind == kind;
}

fn expectPeek(self: *Self, kind: token.TokenKind) !bool {
    if (self.peekTokenIs(kind)) {
        self.nextToken();

        return true;
    }

    try self.peekError(kind);

    return false;
}

fn nextToken(self: *Self) void {
    self.current_token = self.peek_token;
    self.peek_token = self.lexer.nextToken();
}

fn peekError(self: *Self, kind: token.TokenKind) !void {
    const msg = try std.fmt.allocPrint(self.allocator, "expected next token to be {s}, got {s} instead.\n", .{
        @tagName(kind),
        @tagName(self.peek_token.kind),
    });

    try self.errors_.append(self.allocator, msg);
}

fn registerPrefix(self: *Self, kind: token.TokenKind, func: PrefixParseFn) !void {
    try self.prefix_parse_fns.put(kind, func);
}

fn registerInfix(self: *Self, kind: token.TokenKind, func: InfixParseFn) !void {
    try self.infix_parse_fns.put(kind, func);
}

fn noPrefixParseFnError(self: *Self, kind: token.TokenKind) !void {
    const msg = try std.fmt.allocPrint(self.allocator, "no prefix parse function for {s} found", .{
        @tagName(kind),
    });

    try self.errors_.append(self.allocator, msg);
}

fn peekPrecedence(self: Self) Precedence {
    return getPrecedence(self.peek_token.kind);
}

fn currentPrecedence(self: Self) Precedence {
    return getPrecedence(self.current_token.kind);
}

fn getPrecedence(t: token.TokenKind) Precedence {
    return switch (t) {
        .eq, .not_eq => .equals,
        .lt, .gt => .less_greater,
        .plus, .minus => .sum,
        .asterisk, .slash => .product,
        .lparen => .call,
        else => .lowest,
    };
}

const Expected = union(enum) {
    int: i64,
    ident: []const u8,
    boolean: bool,
};

test "let statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\let x = 5;
        \\let y = 10;
        \\let foobar = 838383;
    ;

    const program = try parseAndCheckProgram(allocator, input);

    if (program.statements.items.len != 3) {
        std.debug.print("parseProgram returned null\n", .{});
        return error.NumProgramStatements;
    }

    const tests = [_]struct {
        expected_identifier: []const u8,
    }{
        .{ .expected_identifier = "x" },
        .{ .expected_identifier = "y" },
        .{ .expected_identifier = "foobar" },
    };

    for (tests, 0..) |t, i| {
        const statement = program.statements.items[i];

        try testLetStatement(statement, t.expected_identifier);
    }
}

test "return statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\return 5;
        \\return 10;
        \\return 993322;
    ;

    const program = try parseAndCheckProgram(allocator, input);

    if (program.statements.items.len != 3) {
        std.debug.print("parseProgram returned null\n", .{});
        return error.NumProgramStatements;
    }

    for (program.statements.items) |statement| {
        const return_stmt = switch (statement) {
            .return_statement => |rs| rs,
            else => {
                std.debug.print("stmt not ReturnStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        try testing.expectEqualStrings("return", return_stmt.tokenLiteral());
    }
}

test "identifier expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "foobar;";

    const program = try parseAndCheckProgram(allocator, input);

    if (program.statements.items.len != 1) {
        std.debug.print("parseProgram returned null\n", .{});
        return error.NumProgramStatements;
    }

    const statement = program.statements.items[0];

    const expr_stmt = switch (statement) {
        .expression_statement => |es| es,
        else => {
            std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };

    const ident = switch (expr_stmt.expression.?.*) {
        .identifier_expression => |ie| ie,
        else => {
            std.debug.print("stmt not ast.Identifier. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqualStrings("foobar", ident.value);
    try testing.expectEqualStrings("foobar", ident.tokenLiteral());
}

test "integer literal expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "5;";

    const program = try parseAndCheckProgram(allocator, input);

    if (program.statements.items.len != 1) {
        std.debug.print("parseProgram returned null\n", .{});
        return error.NumProgramStatements;
    }

    const statement = program.statements.items[0];

    const expr_stmt = switch (statement) {
        .expression_statement => |es| es,
        else => {
            std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };

    const literal = switch (expr_stmt.expression.?.*) {
        .integer_literal => |il| il,
        else => {
            std.debug.print("stmt not IntegerLiteral. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqual(5, literal.value);
    try testing.expectEqualStrings("5", literal.tokenLiteral());
}

test "boolean expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "true", .expected = true },
        .{ .input = "false", .expected = false },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input);

        if (program.statements.items.len != 1) {
            std.debug.print("parseProgram returned null\n", .{});
            return error.NumProgramStatements;
        }

        const statement = program.statements.items[0];

        const expr_stmt = switch (statement) {
            .expression_statement => |es| es,
            else => {
                std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        const boolean = switch (expr_stmt.expression.?.*) {
            .boolean_expression => |be| be,
            else => {
                std.debug.print("stmt not PrefixExpression. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        const expected_literal = if (t.expected) "true" else "false";

        try testing.expectEqual(t.expected, boolean.value);
        try testing.expectEqualStrings(expected_literal, boolean.tokenLiteral());
    }
}

test "parsing prefix expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        operator: []const u8,
        expected: Expected,
    }{
        .{ .input = "!5", .operator = "!", .expected = .{ .int = 5 } },
        .{ .input = "-15", .operator = "-", .expected = .{ .int = 15 } },
        .{ .input = "!true", .operator = "!", .expected = .{ .boolean = true } },
        .{ .input = "!false", .operator = "!", .expected = .{ .boolean = false } },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input);

        if (program.statements.items.len != 1) {
            std.debug.print("parseProgram returned null\n", .{});
            return error.NumProgramStatements;
        }

        const statement = program.statements.items[0];

        const expr_stmt = switch (statement) {
            .expression_statement => |es| es,
            else => {
                std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        const exp = switch (expr_stmt.expression.?.*) {
            .prefix_expression => |pe| pe,
            else => {
                std.debug.print("stmt not PrefixExpression. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        try testing.expectEqualStrings(t.operator, exp.operator);
        try testing.expectEqualStrings(t.operator, exp.tokenLiteral());
        try testLiteralExpression(exp.right.?, t.expected);
    }
}

test "parsing infix expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        left_value: Expected,
        operator: []const u8,
        right_value: Expected,
    }{
        .{ .input = "5 + 5;", .left_value = .{ .int = 5 }, .operator = "+", .right_value = .{ .int = 5 } },
        .{ .input = "5 - 5;", .left_value = .{ .int = 5 }, .operator = "-", .right_value = .{ .int = 5 } },
        .{ .input = "5 * 5;", .left_value = .{ .int = 5 }, .operator = "*", .right_value = .{ .int = 5 } },
        .{ .input = "5 / 5;", .left_value = .{ .int = 5 }, .operator = "/", .right_value = .{ .int = 5 } },
        .{ .input = "5 > 5;", .left_value = .{ .int = 5 }, .operator = ">", .right_value = .{ .int = 5 } },
        .{ .input = "5 < 5;", .left_value = .{ .int = 5 }, .operator = "<", .right_value = .{ .int = 5 } },
        .{ .input = "5 == 5;", .left_value = .{ .int = 5 }, .operator = "==", .right_value = .{ .int = 5 } },
        .{ .input = "5 != 5;", .left_value = .{ .int = 5 }, .operator = "!=", .right_value = .{ .int = 5 } },
        .{ .input = "true == true", .left_value = .{ .boolean = true }, .operator = "==", .right_value = .{ .boolean = true } },
        .{ .input = "true != true", .left_value = .{ .boolean = true }, .operator = "!=", .right_value = .{ .boolean = true } },
        .{ .input = "false == false", .left_value = .{ .boolean = false }, .operator = "==", .right_value = .{ .boolean = false } },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input);

        if (program.statements.items.len != 1) {
            std.debug.print("parseProgram returned null\n", .{});
            return error.NumProgramStatements;
        }

        const statement = program.statements.items[0];

        const expr_stmt = switch (statement) {
            .expression_statement => |es| es,
            else => {
                std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        try testInfixExpression(expr_stmt.expression.?, t.left_value, t.operator, t.right_value);
    }
}

test "operator precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "-a * b", .expected = "((-a) * b)" },
        .{ .input = "!-a", .expected = "(!(-a))" },
        .{ .input = "a + b + c", .expected = "((a + b) + c)" },
        .{ .input = "a + b - c", .expected = "((a + b) - c)" },
        .{ .input = "a * b * c", .expected = "((a * b) * c)" },
        .{ .input = "a * b / c", .expected = "((a * b) / c)" },
        .{ .input = "a + b / c", .expected = "(a + (b / c))" },
        .{ .input = "a + b * c + d / e - f", .expected = "(((a + (b * c)) + (d / e)) - f)" },
        .{ .input = "3 + 4; -5 * 5", .expected = "(3 + 4)((-5) * 5)" },
        .{ .input = "5 > 4 == 3 < 4", .expected = "((5 > 4) == (3 < 4))" },
        .{ .input = "5 < 4 != 3 > 4", .expected = "((5 < 4) != (3 > 4))" },
        .{ .input = "3 + 4 * 5 == 3 * 1 + 4 * 5", .expected = "((3 + (4 * 5)) == ((3 * 1) + (4 * 5)))" },
        .{ .input = "true", .expected = "true" },
        .{ .input = "false", .expected = "false" },
        .{ .input = "3 > 5 == false", .expected = "((3 > 5) == false)" },
        .{ .input = "3 < 5 == true", .expected = "((3 < 5) == true)" },
        .{ .input = "1 + (2 + 3) + 4", .expected = "((1 + (2 + 3)) + 4)" },
        .{ .input = "(5 + 5) * 2", .expected = "((5 + 5) * 2)" },
        .{ .input = "2 / (5 + 5)", .expected = "(2 / (5 + 5))" },
        .{ .input = "-(5 + 5)", .expected = "(-(5 + 5))" },
        .{ .input = "!(true == true)", .expected = "(!(true == true))" },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input);

        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        try program.write(&w);

        try testing.expectEqualStrings(t.expected, w.buffered());
    }
}

fn parseAndCheckProgram(allocator: std.mem.Allocator, input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try init(allocator, lexer);
    defer parser.deinit();

    const program = try parser.parseProgram() orelse {
        std.debug.print("parseProgram returned null\n", .{});
        return error.ProgramParse;
    };

    try checkParserErrors(parser);

    return program;
}

fn testLetStatement(statement: ast.Statement, name: []const u8) !void {
    try testing.expectEqualStrings("let", statement.tokenLiteral());

    const let_stmt = switch (statement) {
        .let_statement => |ls| ls,
        else => {
            std.debug.print("stmt not LetStatement. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqualStrings(name, let_stmt.name.value);
    try testing.expectEqualStrings(name, let_stmt.name.tokenLiteral());
}

fn testIntegerLiteral(exp: *ast.Expression, value: i64) !void {
    const literal = switch (exp.*) {
        .integer_literal => |il| il,
        else => {
            std.debug.print("stmt not IntegerLiteral. got={s}\n", .{@tagName(exp.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqual(value, literal.value);
}

fn testIdentifier(exp: *ast.Expression, value: []const u8) !void {
    const ident = switch (exp.*) {
        .identifier_expression => |ie| ie,
        else => {
            std.debug.print("stmt not IdentifierExpressions. got={s}\n", .{@tagName(exp.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqualStrings(value, ident.value);
    try testing.expectEqualStrings(value, ident.tokenLiteral());
}

fn testBooleanLiteral(exp: *ast.Expression, value: bool) !void {
    const literal = switch (exp.*) {
        .boolean_expression => |be| be,
        else => {
            std.debug.print("stmt not BooleanLiteral. got={s}\n", .{@tagName(exp.*)});
            return error.WrongStatementType;
        },
    };

    const expected = if (value) "true" else "false";

    try testing.expectEqual(value, literal.value);
    try testing.expectEqualStrings(expected, literal.tokenLiteral());
}

fn testLiteralExpression(exp: *ast.Expression, expected: Expected) !void {
    switch (expected) {
        .int => |i| try testIntegerLiteral(exp, i),
        .ident => |i| try testIdentifier(exp, i),
        .boolean => |b| try testBooleanLiteral(exp, b),
    }
}

fn testInfixExpression(exp: *ast.Expression, left: Expected, operator: []const u8, right: Expected) !void {
    const infix = switch (exp.*) {
        .infix_expression => |i| i,
        else => {
            std.debug.print("exp not InfixExpression. got={s}\n", .{@tagName(exp.*)});
            return error.WrongExpressionType;
        },
    };

    try testLiteralExpression(infix.left.?, left);
    try testing.expectEqualStrings(operator, infix.operator);
    try testLiteralExpression(infix.right.?, right);
}

fn checkParserErrors(parser: Self) !void {
    for (parser.errors_.items) |err| std.debug.print("{s}\n", .{err});
    try testing.expectEqual(@as(usize, 0), parser.errors_.items.len);
}
