const std = @import("std");
const testing = std.testing;

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

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            inline else => |n| n.write(out),
        };
    }
};

pub const Statement = union(enum) {
    const Self = @This();

    let_statement: LetStatement,
    return_statement: ReturnStatement,
    expression_statement: ExpressionStatement,
    block_statement: BlockStatement,

    pub fn tokenLiteral(self: Self) []const u8 {
        return switch (self) {
            inline else => |s| s.tokenLiteral(),
        };
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            inline else => |s| s.write(out),
        };
    }
};

pub const Expression = union(enum) {
    const Self = @This();

    identifier_expression: Identifier,
    boolean_expression: BooleanExpression,
    if_expression: IfExpression,
    call_expression: CallExpression,

    prefix_expression: PrefixExpression,
    infix_expression: InfixExpression,

    integer_literal: IntegerLiteral,
    function_literal: FunctionLiteral,
    string_literal: StringLiteral,

    pub fn tokenLiteral(self: Self) []const u8 {
        return switch (self) {
            inline else => |e| e.tokenLiteral(),
        };
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self) {
            inline else => |e| e.write(out),
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

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.statements.items) |s| try s.write(out);
    }
};

pub const LetStatement = struct {
    const Self = @This();

    token: token.Token,
    name: Identifier = undefined,
    value: ?*Expression = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("{s} ", .{self.tokenLiteral()});
        try self.name.write(out);
        try out.writeAll(" = ");
        if (self.value) |v| try v.write(out);
        try out.writeByte(';');
    }
};

pub const ReturnStatement = struct {
    const Self = @This();

    token: token.Token,
    return_value: ?*Expression = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("{s} ", .{self.tokenLiteral()});
        if (self.return_value) |v| try v.write(out);
        try out.writeByte(';');
    }
};

pub const ExpressionStatement = struct {
    const Self = @This();

    token: token.Token,
    expression: ?*Expression = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.expression) |e| try e.write(out);
    }
};

pub const Identifier = struct {
    const Self = @This();

    token: token.Token,
    value: []const u8,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll(self.value);
    }
};

pub const IntegerLiteral = struct {
    const Self = @This();

    token: token.Token,
    value: i64 = 0,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("{d}", .{self.value});
    }
};

pub const PrefixExpression = struct {
    const Self = @This();

    token: token.Token,
    operator: []const u8,
    right: ?*Expression = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeByte('(');
        try out.writeAll(self.operator);
        if (self.right) |r| try r.write(out);
        try out.writeByte(')');
    }
};

pub const InfixExpression = struct {
    const Self = @This();

    token: token.Token,
    left: ?*Expression = null,
    operator: []const u8 = "",
    right: ?*Expression = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeByte('(');
        if (self.left) |l| try l.write(out);
        try out.print(" {s} ", .{self.operator});
        if (self.right) |r| try r.write(out);
        try out.writeByte(')');
    }
};

pub const BooleanExpression = struct {
    const Self = @This();

    token: token.Token,
    value: bool,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("{}", .{self.value});
    }
};

pub const IfExpression = struct {
    const Self = @This();

    token: token.Token,
    condition: ?*Expression = null,
    consequence: ?BlockStatement = null,
    alternative: ?BlockStatement = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll("if");
        if (self.condition) |c| try c.write(out);
        try out.writeAll(" ");
        if (self.consequence) |c| try c.write(out);
        if (self.alternative) |a| {
            try out.writeAll("else ");
            try a.write(out);
        }
    }
};

pub const BlockStatement = struct {
    const Self = @This();

    token: token.Token,
    statements: std.ArrayList(Statement) = .empty,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.statements.items) |s| try s.write(out);
    }
};

pub const FunctionLiteral = struct {
    const Self = @This();

    token: token.Token,
    parameters: std.ArrayList(Identifier) = .empty,
    body: ?BlockStatement = null,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll(self.tokenLiteral());
        try out.writeByte('(');
        for (self.parameters.items, 0..) |p, i| {
            if (i != 0) try out.writeAll(", ");
            try p.write(out);
        }
        try out.writeByte(')');
        if (self.body) |b| try b.write(out);
    }
};

pub const CallExpression = struct {
    const Self = @This();

    token: token.Token,
    function: ?*Expression = null,
    arguments: std.ArrayList(*Expression) = .empty,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.function.?.write(out);
        try out.writeByte('(');
        for (self.arguments.items, 0..) |p, i| {
            if (i != 0) try out.writeAll(", ");
            try p.write(out);
        }
        try out.writeByte(')');
    }
};

pub const StringLiteral = struct {
    const Self = @This();

    token: token.Token,
    value: []const u8,

    pub fn tokenLiteral(self: Self) []const u8 {
        return self.token.literal;
    }

    pub fn write(self: Self, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll(self.value);
    }
};

test "write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var program = Program{};
    defer program.statements.deinit(testing.allocator);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const exp = try allocator.create(Expression);

    exp.* = .{ .identifier_expression = .{
        .token = .{ .kind = .ident, .literal = "anotherVar" },
        .value = "anotherVar",
    } };

    try program.statements.append(testing.allocator, .{ .let_statement = .{
        .token = .{ .kind = .let, .literal = "let" },
        .name = .{
            .token = .{ .kind = .ident, .literal = "myVar" },
            .value = "myVar",
        },
        .value = exp,
    } });

    try program.write(&w);

    try testing.expectEqualStrings("let myVar = anotherVar;", w.buffered());
}
