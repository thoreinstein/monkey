const std = @import("std");

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "fn", .function },
    .{ "let", .let },
});

pub const TokenKind = enum {
    illegal,
    eof,

    // identifiers and literals
    ident,
    int,

    // operators
    assign,
    plus,

    // delimeters
    comma,
    semicolon,

    lparen,
    rparen,
    lbrace,
    rbrace,

    // keywords
    function,
    let,
};

pub const Token = struct {
    kind: TokenKind,
    literal: []const u8,
};

pub fn lookupIdentifer(ident: []const u8) TokenKind {
    return keywords.get(ident) orelse .ident;
}
