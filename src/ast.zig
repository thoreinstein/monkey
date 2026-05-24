const std = @import("std");

const token = @import("token.zig");

pub const Node = union(enum) {
    const Self = @This();

    program: Program,
    statement: Statement,
    expression: Expression,

    pub fn tokenLiteral(self: Self) []const u8 {
        return switch (self) {
            inline else => |n| n.tokenLiteral(),
        };
    }
};

pub const Statement = union(enum) {
    const Self = @This();

    let_statement: LetStatement,

    pub fn tokenLiteral(self: Self) []const u8 {
        return switch (self) {
            inline else => |n| n.tokenLiteral(),
        };
    }
};

pub const Expression = union(enum) {
    const Self = @This();

    identifier_expression: Identifier,

    pub fn tokenLiteral(self: Self) []const u8 {
        return switch (self) {
            inline else => |n| n.tokenLiteral(),
        };
    }
};

pub const Program = struct {
    const Self = @This();

    statements: std.ArrayList(Statement) = .empty,

    pub fn tokenLiteral(self: Self) []const u8 {
        if (self.statements.items.len > 0) return self.statements.items[0].tokenLiteral();

        return "";
    }
};

pub const LetStatement = struct {
    const Self = @This();

    token: token.Token,
    name: Identifier = undefined,
    value: Expression = undefined,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }
};

pub const Identifier = struct {
    const Self = @This();

    token: token.Token,
    value: []const u8,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }
};
