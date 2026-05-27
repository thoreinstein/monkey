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
    try parser.registerPrefix(.if_, Self.parseIfExpression);
    try parser.registerPrefix(.function, Self.parseFunctionLiteral);
    try parser.registerPrefix(.string, Self.parseStringLiteral);
    try parser.registerPrefix(.lbracket, Self.parseArrayLiteral);

    try parser.registerInfix(.plus, Self.parseInfixExpression);
    try parser.registerInfix(.minus, Self.parseInfixExpression);
    try parser.registerInfix(.slash, Self.parseInfixExpression);
    try parser.registerInfix(.asterisk, Self.parseInfixExpression);
    try parser.registerInfix(.eq, Self.parseInfixExpression);
    try parser.registerInfix(.not_eq, Self.parseInfixExpression);
    try parser.registerInfix(.lt, Self.parseInfixExpression);
    try parser.registerInfix(.gt, Self.parseInfixExpression);
    try parser.registerInfix(.lparen, Self.parseCallExpression);

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

    self.nextToken();

    statement.value = try self.parseExpression(.lowest);

    if (self.peekTokenIs(.semicolon)) self.nextToken();

    return statement;
}

fn parseReturnStatement(self: *Self) !?ast.ReturnStatement {
    var statement = ast.ReturnStatement{
        .token = self.current_token,
    };

    self.nextToken();

    statement.return_value = try self.parseExpression(.lowest);

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

fn parseBlockStatement(self: *Self) !?ast.BlockStatement {
    var block = ast.BlockStatement{ .token = self.current_token };

    self.nextToken();

    while (!self.currentTokenIs(.rbrace) and !self.currentTokenIs(.eof)) {
        const statement = try self.parseStatement();
        if (statement) |s| try block.statements.append(self.allocator, s);
        self.nextToken();
    }

    return block;
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

fn parseCallExpression(self: *Self, function: *ast.Expression) !?ast.Expression {
    var expression = ast.CallExpression{
        .token = self.current_token,
        .function = function,
    };

    const args = try self.parseCallArguments() orelse return null;

    expression.arguments = args;

    return .{
        .call_expression = expression,
    };
}

fn parseCallArguments(self: *Self) !?std.ArrayList(*ast.Expression) {
    var args = std.ArrayList(*ast.Expression).empty;

    if (self.peekTokenIs(.rparen)) {
        self.nextToken();

        return args;
    }

    self.nextToken();

    const arg = try self.parseExpression(.lowest) orelse return null;
    try args.append(self.allocator, arg);

    while (self.peekTokenIs(.comma)) {
        self.nextToken();
        self.nextToken();
        const a = try self.parseExpression(.lowest) orelse return null;
        try args.append(self.allocator, a);
    }

    if (!(try self.expectPeek(.rparen))) return null;

    return args;
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

fn parseStringLiteral(self: *Self) !?*ast.Expression {
    const new = try self.allocator.create(ast.Expression);

    new.* = .{ .string_literal = .{ .token = self.current_token, .value = self.current_token.literal } };

    return new;
}

fn parseArrayLiteral(self: *Self) !?*ast.Expression {
    const new = try self.allocator.create(ast.Expression);

    const elements = try self.parseExpressionList(.rbracket) orelse return null;

    new.* = .{ .array_literal = .{
        .token = self.current_token,
        .elements = elements,
    } };

    return new;
}

fn parseExpressionList(self: *Self, end: token.TokenKind) !?std.ArrayList(*ast.Expression) {
    var list = std.ArrayList(*ast.Expression).empty;

    if (self.peekTokenIs(end)) {
        self.nextToken();

        return list;
    }

    self.nextToken();

    const exp = try self.parseExpression(.lowest) orelse return null;
    try list.append(self.allocator, exp);

    while (self.peekTokenIs(.comma)) {
        self.nextToken();
        self.nextToken();

        const e = try self.parseExpression(.lowest) orelse return null;
        try list.append(self.allocator, e);
    }

    if (!(try self.expectPeek(end))) return null;

    return list;
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

fn parseIfExpression(self: *Self) !?*ast.Expression {
    var expression = ast.IfExpression{
        .token = self.current_token,
    };

    if (!(try self.expectPeek(.lparen))) return null;

    self.nextToken();

    expression.condition = try self.parseExpression(.lowest);

    if (!(try self.expectPeek(.rparen))) return null;
    if (!(try self.expectPeek(.lbrace))) return null;

    expression.consequence = try self.parseBlockStatement();

    if (self.peekTokenIs(.else_)) {
        self.nextToken();

        if (!(try self.expectPeek(.lbrace))) return null;

        expression.alternative = try self.parseBlockStatement();
    }

    const new = try self.allocator.create(ast.Expression);

    new.* = .{
        .if_expression = expression,
    };

    return new;
}

fn parseFunctionLiteral(self: *Self) !?*ast.Expression {
    var literal = ast.FunctionLiteral{
        .token = self.current_token,
    };

    if (!(try self.expectPeek(.lparen))) return null;

    literal.parameters = try self.parseFunctionParameters() orelse return null;

    if (!(try self.expectPeek(.lbrace))) return null;

    literal.body = try self.parseBlockStatement();

    const new = try self.allocator.create(ast.Expression);

    new.* = .{
        .function_literal = literal,
    };

    return new;
}

fn parseFunctionParameters(self: *Self) !?std.ArrayList(ast.Identifier) {
    var identifiers = std.ArrayList(ast.Identifier).empty;

    if (self.peekTokenIs(.rparen)) {
        self.nextToken();

        return identifiers;
    }

    self.nextToken();

    const ident = ast.Identifier{ .token = self.current_token, .value = self.current_token.literal };
    try identifiers.append(self.allocator, ident);

    while (self.peekTokenIs(.comma)) {
        self.nextToken();
        self.nextToken();

        const i = ast.Identifier{ .token = self.current_token, .value = self.current_token.literal };
        try identifiers.append(self.allocator, i);
    }

    if (!(try self.expectPeek(.rparen))) return null;

    return identifiers;
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

    const tests = [_]struct {
        input: []const u8,
        expected_identifier: []const u8,
        expected_value: Expected,
    }{
        .{ .input = "let x = 5;", .expected_identifier = "x", .expected_value = .{ .int = 5 } },
        .{ .input = "let y = true;", .expected_identifier = "y", .expected_value = .{ .boolean = true } },
        .{ .input = "let foobar = y;", .expected_identifier = "foobar", .expected_value = .{ .ident = "y" } },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const statement = program.statements.items[0];

        try testLetStatement(statement, t.expected_identifier);

        const let_stmt = switch (statement) {
            .let_statement => |ls| ls,
            else => {
                std.debug.print("stmt not LetStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        try testLiteralExpression(let_stmt.value.?, t.expected_value);
    }
}

test "return statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: Expected,
    }{
        .{ .input = "return 5;", .expected = .{ .int = 5 } },
        .{ .input = "return true;", .expected = .{ .boolean = true } },
        .{ .input = "return y;", .expected = .{ .ident = "y" } },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const statement = program.statements.items[0];

        const return_stmt = switch (statement) {
            .return_statement => |rs| rs,
            else => {
                std.debug.print("stmt not ReturnStatement. got={s}\n", .{@tagName(statement)});
                return error.WrongStatementType;
            },
        };

        try testing.expectEqualStrings("return", return_stmt.tokenLiteral());

        try testLiteralExpression(return_stmt.return_value.?, t.expected);
    }
}

test "identifier expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "foobar;";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const ident = switch (expr_stmt.expression.?.*) {
        .identifier_expression => |ie| ie,
        else => {
            std.debug.print("stmt not ast.Identifier. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
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

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const literal = switch (expr_stmt.expression.?.*) {
        .integer_literal => |il| il,
        else => {
            std.debug.print("stmt not IntegerLiteral. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
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
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const expr_stmt = try getExpressionStatement(program);

        const boolean = switch (expr_stmt.expression.?.*) {
            .boolean_expression => |be| be,
            else => {
                std.debug.print("stmt not PrefixExpression. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
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
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const expr_stmt = try getExpressionStatement(program);

        const exp = switch (expr_stmt.expression.?.*) {
            .prefix_expression => |pe| pe,
            else => {
                std.debug.print("stmt not PrefixExpression. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
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
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const expr_stmt = try getExpressionStatement(program);

        try testInfixExpression(expr_stmt.expression.?, t.left_value, t.operator, t.right_value);
    }
}

test "if expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if (x < y) { x }";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const if_exp = switch (expr_stmt.expression.?.*) {
        .if_expression => |ie| ie,
        else => {
            std.debug.print("stmt not IfExpression. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testInfixExpression(if_exp.condition.?, .{ .ident = "x" }, "<", .{ .ident = "y" });

    try testing.expectEqual(@as(usize, 1), if_exp.consequence.?.statements.items.len);
    try testing.expectEqual(null, if_exp.alternative);

    const consequence = switch (if_exp.consequence.?.statements.items[0]) {
        .expression_statement => |es| es,
        else => {
            std.debug.print("consequence not ExpressionStatement. got={s}\n", .{@tagName(if_exp.consequence.?.statements.items[0])});
            return error.WrongStatementType;
        },
    };

    try testIdentifier(consequence.expression.?, "x");
}

test "if else expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if (x < y) { x } else { y }";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const exp = switch (expr_stmt.expression.?.*) {
        .if_expression => |p| p,
        else => {
            std.debug.print("stmt not IfExpression. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqual(1, exp.consequence.?.statements.items.len);
    try testing.expectEqual(1, exp.alternative.?.statements.items.len);
    try testInfixExpression(exp.condition.?, .{ .ident = "x" }, "<", .{ .ident = "y" });

    const consequence_stmt = switch (exp.consequence.?.statements.items[0]) {
        .expression_statement => |s| s,
        else => {
            std.debug.print("consequence stmt not ExpressionStatement. got={s}\n", .{@tagName(exp.consequence.?.statements.items[0])});
            return error.WrongStatementType;
        },
    };
    try testIdentifier(consequence_stmt.expression.?, "x");

    const alternative_stmt = switch (exp.alternative.?.statements.items[0]) {
        .expression_statement => |s| s,
        else => {
            std.debug.print("alternative stmt not ExpressionStatement. got={s}\n", .{@tagName(exp.alternative.?.statements.items[0])});
            return error.WrongStatementType;
        },
    };
    try testIdentifier(alternative_stmt.expression.?, "y");
}

test "function literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "fn(x, y) { x + y; }";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const fun_literal = switch (expr_stmt.expression.?.*) {
        .function_literal => |fl| fl,
        else => {
            std.debug.print("stmt not FunctionLiteral. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqual(@as(usize, 2), fun_literal.parameters.items.len);
    try testing.expectEqual(@as(usize, 1), fun_literal.body.?.statements.items.len);

    try testing.expectEqualStrings("x", fun_literal.parameters.items[0].value);
    try testing.expectEqualStrings("y", fun_literal.parameters.items[1].value);

    const body_stmt = switch (fun_literal.body.?.statements.items[0]) {
        .expression_statement => |es| es,
        else => {
            std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testInfixExpression(body_stmt.expression.?, .{ .ident = "x" }, "+", .{ .ident = "y" });
}

test "function parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: []const []const u8,
    }{
        .{ .input = "fn() {};", .expected = &.{} },
        .{ .input = "fn(x) {};", .expected = &.{"x"} },
        .{ .input = "fn(x, y, z) {};", .expected = &.{ "x", "y", "z" } },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input, 1);

        const expr_stmt = try getExpressionStatement(program);

        const fun_literal = switch (expr_stmt.expression.?.*) {
            .function_literal => |fl| fl,
            else => {
                std.debug.print("stmt not FunctionLiteral. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
                return error.WrongStatementType;
            },
        };

        try testing.expectEqual(@as(usize, t.expected.len), fun_literal.parameters.items.len);

        for (t.expected, 0..) |ident, i| {
            try testing.expectEqualStrings(ident, fun_literal.parameters.items[i].value);
        }
    }
}

test "call expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "add(1, 2 * 3, 4 + 5);";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const call_exp = switch (expr_stmt.expression.?.*) {
        .call_expression => |ce| ce,
        else => {
            std.debug.print("stmt not CallExpression. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqualStrings("add", call_exp.function.?.tokenLiteral());
    try testing.expectEqual(@as(usize, 3), call_exp.arguments.items.len);

    try testLiteralExpression(call_exp.arguments.items[0], .{ .int = 1 });
    try testInfixExpression(call_exp.arguments.items[1], .{ .int = 2 }, "*", .{ .int = 3 });
    try testInfixExpression(call_exp.arguments.items[2], .{ .int = 4 }, "+", .{ .int = 5 });
}

test "operator precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
        size: usize,
    }{
        .{ .input = "-a * b", .expected = "((-a) * b)", .size = 1 },
        .{ .input = "!-a", .expected = "(!(-a))", .size = 1 },
        .{ .input = "a + b + c", .expected = "((a + b) + c)", .size = 1 },
        .{ .input = "a + b - c", .expected = "((a + b) - c)", .size = 1 },
        .{ .input = "a * b * c", .expected = "((a * b) * c)", .size = 1 },
        .{ .input = "a * b / c", .expected = "((a * b) / c)", .size = 1 },
        .{ .input = "a + b / c", .expected = "(a + (b / c))", .size = 1 },
        .{ .input = "a + b * c + d / e - f", .expected = "(((a + (b * c)) + (d / e)) - f)", .size = 1 },
        .{ .input = "3 + 4; -5 * 5", .expected = "(3 + 4)((-5) * 5)", .size = 2 },
        .{ .input = "5 > 4 == 3 < 4", .expected = "((5 > 4) == (3 < 4))", .size = 1 },
        .{ .input = "5 < 4 != 3 > 4", .expected = "((5 < 4) != (3 > 4))", .size = 1 },
        .{ .input = "3 + 4 * 5 == 3 * 1 + 4 * 5", .expected = "((3 + (4 * 5)) == ((3 * 1) + (4 * 5)))", .size = 1 },
        .{ .input = "true", .expected = "true", .size = 1 },
        .{ .input = "false", .expected = "false", .size = 1 },
        .{ .input = "3 > 5 == false", .expected = "((3 > 5) == false)", .size = 1 },
        .{ .input = "3 < 5 == true", .expected = "((3 < 5) == true)", .size = 1 },
        .{ .input = "1 + (2 + 3) + 4", .expected = "((1 + (2 + 3)) + 4)", .size = 1 },
        .{ .input = "(5 + 5) * 2", .expected = "((5 + 5) * 2)", .size = 1 },
        .{ .input = "2 / (5 + 5)", .expected = "(2 / (5 + 5))", .size = 1 },
        .{ .input = "-(5 + 5)", .expected = "(-(5 + 5))", .size = 1 },
        .{ .input = "!(true == true)", .expected = "(!(true == true))", .size = 1 },
        .{ .input = "a + add(b * c) + d", .expected = "((a + add((b * c))) + d)", .size = 1 },
        .{ .input = "add(a, b, 1, 2 * 3, 4 + 5, add(6, 7 * 8))", .expected = "add(a, b, 1, (2 * 3), (4 + 5), add(6, (7 * 8)))", .size = 1 },
        .{ .input = "add(a + b + c * d / f + g)", .expected = "add((((a + b) + ((c * d) / f)) + g))", .size = 1 },
    };

    for (tests) |t| {
        const program = try parseAndCheckProgram(allocator, t.input, t.size);

        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        try program.write(&w);

        try testing.expectEqualStrings(t.expected, w.buffered());
    }
}

test "string literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "\"hello world\"";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const str_lit = switch (expr_stmt.expression.?.*) {
        .string_literal => |sl| sl,
        else => {
            std.debug.print("stmt not StringLiteral. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testing.expectEqualStrings("hello world", str_lit.value);
}

test "array literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "[1, 2 * 2, 3 + 3]";

    const program = try parseAndCheckProgram(allocator, input, 1);

    const expr_stmt = try getExpressionStatement(program);

    const array_lit = switch (expr_stmt.expression.?.*) {
        .array_literal => |al| al,
        else => {
            std.debug.print("stmt not ArrayLiteral. got={s}\n", .{@tagName(expr_stmt.expression.?.*)});
            return error.WrongStatementType;
        },
    };

    try testIntegerLiteral(array_lit.elements.items[0], 1);
    try testInfixExpression(array_lit.elements.items[1], .{ .int = 2 }, "*", .{ .int = 2 });
    try testInfixExpression(array_lit.elements.items[2], .{ .int = 3 }, "+", .{ .int = 3 });
}

fn parseAndCheckProgram(allocator: std.mem.Allocator, input: []const u8, size: usize) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = try init(allocator, lexer);
    defer parser.deinit();

    const program = try parser.parseProgram() orelse {
        std.debug.print("parseProgram returned null\n", .{});
        return error.ProgramParse;
    };

    try testing.expectEqual(size, program.statements.items.len);

    try checkParserErrors(parser);

    return program;
}

fn getExpressionStatement(program: ast.Program) !ast.ExpressionStatement {
    const statement = program.statements.items[0];

    return switch (statement) {
        .expression_statement => |es| es,
        else => {
            std.debug.print("stmt not ExpressionStatement. got={s}\n", .{@tagName(statement)});
            return error.WrongStatementType;
        },
    };
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
