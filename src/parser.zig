const std = @import("std");
const testing = std.testing;

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");
const token = @import("token.zig");

const Self = @This();

allocator: std.mem.Allocator,
lexer: Lexer,

current_token: token.Token = undefined,
errors_: std.ArrayList([]const u8) = .empty,
peek_token: token.Token = undefined,

pub fn init(allocator: std.mem.Allocator, lexer: Lexer) Self {
    var parser = Self{
        .allocator = allocator,
        .lexer = lexer,
    };

    parser.nextToken();
    parser.nextToken();

    return parser;
}

pub fn deinit(self: *Self) void {
    for (self.errors_.items) |msg| self.allocator.free(msg);
    self.errors_.deinit(self.allocator);
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
        else => return null,
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

test "let statements" {
    const input =
        \\let x = 5;
        \\let y = 10;
        \\let foobar = 838383;
    ;

    var program = try parseAndCheckProgram(input);
    defer program.statements.deinit(testing.allocator);

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
    const input =
        \\return 5;
        \\return 10;
        \\return 993322;
    ;

    var program = try parseAndCheckProgram(input);
    defer program.statements.deinit(testing.allocator);

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

fn parseAndCheckProgram(input: []const u8) !ast.Program {
    const lexer = Lexer.init(input);
    var parser = init(testing.allocator, lexer);
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

fn checkParserErrors(parser: Self) !void {
    for (parser.errors_.items) |err| std.debug.print("{s}", .{err});
    try testing.expectEqual(@as(usize, 0), parser.errors_.items.len);
}
