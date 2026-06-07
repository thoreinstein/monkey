const std = @import("std");
const io = std.Io;
const clap = @import("clap");

const Compiler = @import("compiler.zig");
const Environment = @import("environment.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const VM = @import("vm.zig");

const code = @import("code.zig");
const repl = @import("repl.zig");

const SubCommands = enum { run, dis, repl };

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help    Display help and exit
    \\<command>
);

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var out_w = io.File.stdout().writer(init.io, &out_buf);
    const out = &out_w.interface;

    var in_buf: [4096]u8 = undefined;
    var in_r = io.File.stdin().reader(init.io, &in_buf);
    const in = &in_r.interface;

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    var diag = clap.Diagnostic{};

    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);

        return err;
    };
    defer res.deinit();

    const command = res.positionals[0] orelse return try printHelp(out);

    switch (command) {
        .run => try runMain(init, &iter, out),
        .dis => try runDis(init, &iter, out),
        .repl => _ = try repl.start(init.gpa, in, out),
    }
}

fn runMain(init: std.process.Init, iter: *std.process.Args.Iterator, out: *io.Writer) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display help and exit.
        \\-t, --time    Print execution time to stderr.
        \\<str>         Path to the .mky file.
        \\
    );

    var diag = clap.Diagnostic{};

    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        std.process.exit(1);
    };
    defer res.deinit();

    const path = res.positionals[0] orelse {
        std.debug.print("usage: monkey run <file>\n", .{});
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const source = io.Dir.cwd().readFileAlloc(init.io, path, arena.allocator(), .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("monkey: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    const lexer = Lexer.init(source);
    var parser = try Parser.init(arena.allocator(), lexer);
    const program = try parser.parseProgram() orelse std.process.exit(2);

    if (parser.errors_.items.len != 0) {
        for (parser.errors_.items) |msg| std.debug.print("parse error: {s}\n", .{msg});
        std.process.exit(2);
    }

    var compiler = try Compiler.init(arena.allocator());

    compiler.compile(arena.allocator(), .{ .program = program }) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };

    var machine = try VM.init(arena.allocator(), compiler.bytecode());

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    machine.run() catch |err| {
        std.debug.print("runtime error: {s}\n", .{@errorName(err)});
        std.process.exit(4);
    };
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.toMilliseconds();

    if (res.args.time != 0) std.debug.print("run duration: {d}ms\n", .{elapsed});

    const result = machine.lastPoppedStackElem();

    try out.print("{s}\n", .{try result.inspect(arena.allocator())});
    try out.flush();
}

fn runDis(init: std.process.Init, iter: *std.process.Args.Iterator, out: *io.Writer) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display help and exit.
        \\<str>         Path to the .mky file.
        \\
    );

    var diag = clap.Diagnostic{};

    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        std.process.exit(1);
    };
    defer res.deinit();

    const path = res.positionals[0] orelse {
        std.debug.print("usage: monkey run <file>\n", .{});
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const source = io.Dir.cwd().readFileAlloc(init.io, path, arena.allocator(), .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("monkey: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    const lexer = Lexer.init(source);
    var parser = try Parser.init(arena.allocator(), lexer);
    const program = try parser.parseProgram() orelse std.process.exit(2);

    if (parser.errors_.items.len != 0) {
        for (parser.errors_.items) |msg| std.debug.print("parse error: {s}\n", .{msg});
        std.process.exit(2);
    }

    var compiler = try Compiler.init(arena.allocator());

    compiler.compile(arena.allocator(), .{ .program = program }) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };

    const formatted = try code.formatInstructions(arena.allocator(), compiler.bytecode().instructions);

    try out.writeAll(formatted);
    try out.flush();
}
fn printHelp(out: *io.Writer) !void {
    try out.writeAll(
        \\monkey - The Monkey programming language
        \\
        \\usage: monkey [-h] <commnad>
        \\
        \\commands:
        \\  run     <file>  compile and run a .mky file
        \\  dis     <file>  disassemble a .mky file
        \\  repl            start an interactive session
    );
    try out.flush();
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
