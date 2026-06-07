const std = @import("std");
const io = std.Io;
const clap = @import("clap");

const Environment = @import("environment.zig");
const repl = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var out_w = io.File.stdout().writer(init.io, &out_buf);
    const out = &out_w.interface;

    var in_buf: [4096]u8 = undefined;
    var in_r = io.File.stdin().reader(init.io, &in_buf);
    const in = &in_r.interface;

    _ = try repl.start(init.gpa, in, out);
}

test {
    _ = @import("ast.zig");
    _ = @import("code.zig");
    _ = @import("compiler.zig");
    _ = @import("evaluator.zig");
    _ = @import("lexer.zig");
    _ = @import("object.zig");
    _ = @import("parser.zig");
    _ = @import("repl.zig");
    _ = @import("token.zig");
    _ = @import("vm.zig");
}
