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

pub fn nextToken(self: *Self) token.Token {
    self.skipWhitespace();

    const tok: token.Token = switch (self.ch) {
        ';' => .{ .kind = .semicolon, .literal = ";" },
        '*' => .{ .kind = .asterisk, .literal = "*" },
        '<' => .{ .kind = .lt, .literal = "<" },
        '>' => .{ .kind = .gt, .literal = ">" },
        '(' => .{ .kind = .lparen, .literal = "(" },
        ')' => .{ .kind = .rparen, .literal = ")" },
        ',' => .{ .kind = .comma, .literal = "," },
        '{' => .{ .kind = .lbrace, .literal = "{" },
        '}' => .{ .kind = .rbrace, .literal = "}" },
        '[' => .{ .kind = .lbracket, .literal = "[" },
        ']' => .{ .kind = .rbracket, .literal = "]" },
        ':' => .{ .kind = .colon, .literal = ":" },
        '"' => .{ .kind = .string, .literal = self.readString() },
        0 => .{ .kind = .eof, .literal = "" },
        '-' => blk: {
            if (self.peekChar() == '=') {
                self.readChar();

                break :blk .{ .kind = .minus_assign, .literal = "-=" };
            }

            break :blk .{ .kind = .minus, .literal = "-" };
        },
        '+' => blk: {
            if (self.peekChar() == '=') {
                self.readChar();

                break :blk .{ .kind = .plus_assign, .literal = "+=" };
            }

            break :blk .{ .kind = .plus, .literal = "+" };
        },
        '/' => blk: {
            if (self.peekChar() == '/') {
                while (self.ch != '\n' and self.ch != 0) self.readChar();

                return self.nextToken();
            }

            break :blk .{ .kind = .slash, .literal = "/" };
        },
        '=' => blk: {
            if (self.peekChar() == '=') {
                self.readChar();

                break :blk .{ .kind = .eq, .literal = "==" };
            }

            break :blk .{ .kind = .assign, .literal = "=" };
        },
        '!' => blk: {
            if (self.peekChar() == '=') {
                self.readChar();

                break :blk .{ .kind = .not_eq, .literal = "!=" };
            }

            break :blk .{ .kind = .bang, .literal = "!" };
        },
        else => blk: {
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

            break :blk .{ .kind = .illegal, .literal = "" };
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

fn readChar(self: *Self) void {
    self.ch = if (self.read_position >= self.input.len) 0 else self.input[self.read_position];
    self.position = self.read_position;
    self.read_position += 1;
}

fn readString(self: *Self) []const u8 {
    const position = self.position + 1;

    self.readChar();

    while (self.ch != '"' and self.ch != 0) self.readChar();

    return self.input[position..self.position];
}

fn peekChar(self: *const Self) u8 {
    return if (self.read_position >= self.input.len) 0 else self.input[self.read_position];
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
        \\!-/*5;
        \\5 < 10 > 5;
        \\
        \\if (5 < 10) {
        \\  return true;
        \\} else {
        \\  return false;
        \\}
        \\
        \\10 == 10;
        \\10 != 9;
        \\"foobar"
        \\"foo bar"
        \\[1, 2];
        \\{"foo": "bar"}
        \\let a = 5; // this is a comment
        \\// full line comment
        \\let b = a / 2;
        \\x += 1;
        \\x -= 1;
        \\while (i < 5) { i += 1; };
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
        .{ .kind = .bang, .literal = "!" },
        .{ .kind = .minus, .literal = "-" },
        .{ .kind = .slash, .literal = "/" },
        .{ .kind = .asterisk, .literal = "*" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .lt, .literal = "<" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .gt, .literal = ">" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .if_, .literal = "if" },
        .{ .kind = .lparen, .literal = "(" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .lt, .literal = "<" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .rparen, .literal = ")" },
        .{ .kind = .lbrace, .literal = "{" },
        .{ .kind = .return_, .literal = "return" },
        .{ .kind = .true_, .literal = "true" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .rbrace, .literal = "}" },
        .{ .kind = .else_, .literal = "else" },
        .{ .kind = .lbrace, .literal = "{" },
        .{ .kind = .return_, .literal = "return" },
        .{ .kind = .false_, .literal = "false" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .rbrace, .literal = "}" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .eq, .literal = "==" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .int, .literal = "10" },
        .{ .kind = .not_eq, .literal = "!=" },
        .{ .kind = .int, .literal = "9" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .string, .literal = "foobar" },
        .{ .kind = .string, .literal = "foo bar" },
        .{ .kind = .lbracket, .literal = "[" },
        .{ .kind = .int, .literal = "1" },
        .{ .kind = .comma, .literal = "," },
        .{ .kind = .int, .literal = "2" },
        .{ .kind = .rbracket, .literal = "]" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .lbrace, .literal = "{" },
        .{ .kind = .string, .literal = "foo" },
        .{ .kind = .colon, .literal = ":" },
        .{ .kind = .string, .literal = "bar" },
        .{ .kind = .rbrace, .literal = "}" },
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "a" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .let, .literal = "let" },
        .{ .kind = .ident, .literal = "b" },
        .{ .kind = .assign, .literal = "=" },
        .{ .kind = .ident, .literal = "a" },
        .{ .kind = .slash, .literal = "/" },
        .{ .kind = .int, .literal = "2" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .ident, .literal = "x" },
        .{ .kind = .plus_assign, .literal = "+=" },
        .{ .kind = .int, .literal = "1" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .ident, .literal = "x" },
        .{ .kind = .minus_assign, .literal = "-=" },
        .{ .kind = .int, .literal = "1" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .while_, .literal = "while" },
        .{ .kind = .lparen, .literal = "(" },
        .{ .kind = .ident, .literal = "i" },
        .{ .kind = .lt, .literal = "<" },
        .{ .kind = .int, .literal = "5" },
        .{ .kind = .rparen, .literal = ")" },
        .{ .kind = .lbrace, .literal = "{" },
        .{ .kind = .ident, .literal = "i" },
        .{ .kind = .plus_assign, .literal = "+=" },
        .{ .kind = .int, .literal = "1" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .rbrace, .literal = "}" },
        .{ .kind = .semicolon, .literal = ";" },
        .{ .kind = .eof, .literal = "" },
    };

    var lexer = init(input);

    for (tests, 0..) |t, i| {
        const tok = lexer.nextToken();

        errdefer std.debug.print("Test failed at index {d}: {}", .{ i, tests[i] });

        try testing.expectEqual(t.kind, tok.kind);
        try testing.expectEqualStrings(t.literal, tok.literal);
    }
}
