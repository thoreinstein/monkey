const std = @import("std");
const io = std.Io;

const Environment = @import("environment.zig");
const Evaluator = @import("evaluator.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const PROMPT = ">> ";

pub fn start(allocator: std.mem.Allocator, env: *Environment, in: *io.Reader, out: *io.Writer) !?void {
    while (true) {
        try out.writeAll(PROMPT);
        try out.flush();

        const line = in.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        in.toss(1);

        const lexer = Lexer.init(line);
        var parser = try Parser.init(arena.allocator(), lexer);

        const program = try parser.parseProgram() orelse return null;

        if (parser.errors_.items.len != 0) {
            for (parser.errors().items) |msg| try out.print("\t{s}\n", .{msg});
            try out.flush();
            continue;
        }

        const evaluated = try Evaluator.eval(allocator, .{ .program = program }, env) orelse {
            try out.flush();
            continue;
        };

        const rendered = try evaluated.inspect(allocator);

        try out.writeAll(rendered);
        try out.writeAll("\n");

        try out.flush();
    }
}
