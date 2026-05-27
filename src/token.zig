const std = @import("std");

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "fn", .function },
    .{ "let", .let },
    .{ "if", .if_ },
    .{ "else", .else_ },
    .{ "return", .return_ },
    .{ "true", .true_ },
    .{ "false", .false_ },
});

pub const TokenKind = enum {
    illegal,
    eof,

    // identifiers and literals
    ident,
    int,
    string,

    // operators
    assign,
    plus,
    minus,
    bang,
    asterisk,
    slash,
    lt,
    gt,
    eq,
    not_eq,

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
    if_,
    else_,
    return_,
    true_,
    false_,
};

pub const Token = struct {
    kind: TokenKind,
    literal: []const u8,
};

pub fn lookupIdentifer(ident: []const u8) TokenKind {
    return keywords.get(ident) orelse .ident;
}
