const std = @import("std");
const testing = std.testing;

const token = @import("token.zig");

const Self = @This();

input: []const u8,
position: usize = 0,
read_position: usize = 0,
ch: u8 = 0,

pub fn init(input: []const u8) Self {
    var lexer = Self{
        .input = input,
    };
    lexer.readChar();

    return lexer;
}

pub fn readChar(self: *Self) void {
    self.ch = if (self.read_position >= self.input.len) 0 else self.input[self.read_position];
    self.position = self.read_position;
    self.read_position += 1;
}

pub fn nextToken(self: *Self) token.Token {
    self.skipWhitespace();

    const tok: token.Token = switch (self.ch) {
        '=' => .{ .kind = .assign, .literal = "=" },
        ';' => .{ .kind = .semicolon, .literal = ";" },
        '(' => .{ .kind = .lparen, .literal = "(" },
        ')' => .{ .kind = .rparen, .literal = ")" },
        ',' => .{ .kind = .comma, .literal = "," },
        '+' => .{ .kind = .plus, .literal = "+" },
        '{' => .{ .kind = .lbrace, .literal = "{" },
        '}' => .{ .kind = .rbrace, .literal = "}" },
        '0' => .{ .kind = .eof, .literal = "" },
        else => {
            if (isLetter(self.ch)) {
                const literal = self.readIdentifier();

                return .{
                    .kind = token.lookupIdentifer(literal),
                    .literal = literal,
                };
            }

            if (isDigit(self.ch)) {
                return .{ .kind = .int, .literal = self.readNumber() };
            }

            return .{ .kind = .illegal, .literal = "" };
        },
    };

    self.readChar();

    return tok;
}

fn readIdentifier(self: *Self) []const u8 {
    const pos = self.position;

    while (isLetter(self.ch)) self.readChar();

    return self.input[pos..self.position];
}

fn readNumber(self: *Self) []const u8 {
    const pos = self.position;

    while (isDigit(self.ch)) self.readChar();

    return self.input[pos..self.position];
}

fn skipWhitespace(self: *Self) void {
    while (self.ch == ' ' or self.ch == '\t' or self.ch == '\n' or self.ch == '\r') self.readChar();
}

fn isLetter(ch: u8) bool {
    return ('a' <= ch and ch <= 'z') or ('A' <= ch and ch <= 'Z') or ch == '_';
}

fn isDigit(ch: u8) bool {
    return '0' <= ch and ch <= '9';
}

test "next token" {
    const input =
        \\let five = 5;
        \\let ten = 10;
        \\
        \\let add = fn(x, y) {
        \\  x + y;
        \\};
        \\
        \\let result = add(five, ten);
    ;

    const tests = [_]struct {
        kind: token.TokenKind,
        literal: []const u8,
    }{
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "five" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "ten" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "add" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .function, .literal = "fn" },
        .{ .kind = .lparen, .literal = "(" },
        .{ .kind = .ident, .literal = "x" },
        .{ .kind = .comma, .literal = "," },
        .{ .kind = .ident, .literal = "y" },
        .{ .kind = .rparen, .literal = ")" },
        .{ .kind = .lbrace, .literal = "{" },
        .{ .kind = .ident, .literal = "x" },
        .{ .kind = .plus, .literal = "+" },
        .{ .kind = .ident, .literal = "y" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .rbrace, .literal = "}" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "result" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .ident, .literal = "add" },
        .{ .kind = .lparen, .literal = "(" },
        .{ .kind = .ident, .literal = "five" },
        .{ .kind = .comma, .literal = "," },
        .{ .kind = .ident, .literal = "ten" },
        .{ .kind = .rparen, .literal = ")" },
        .{ .kind = .semicolon, .literal = ";" },
    };

    var lexer = init(input);

    for (tests) |t| {
        const tok = lexer.nextToken();

        try testing.expectEqual(t.kind, tok.kind);
        try testing.expectEqualStrings(t.literal, tok.literal);
    }
}
