const std = @import("std");
const io = std.Io;

const repl = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var out_w = io.File.stdout().writer(init.io, &out_buf);
    const out = &out_w.interface;

    var in_buf: [4096]u8 = undefined;
    var in_r = io.File.stdin().reader(init.io, &in_buf);
    const in = &in_r.interface;

    try repl.start(in, out);
}
