const std = @import("std");
const io = std.Io;

const Lexer = @import("lexer.zig");

const PROMPT = ">> ";

pub fn start(in: *io.Reader, out: *io.Writer) !void {
    while (true) {
        try out.writeAll(PROMPT);
        try out.flush();

        const line = in.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        in.toss(1);

        var lexer = Lexer.init(line);

        while (true) {
            const tok = lexer.nextToken();

            if (tok.kind == .eof) break;

            try out.print("{any}\n", .{tok});
        }

        try out.flush();
    }
}
