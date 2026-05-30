const std = @import("std");
const io = std.Io;

const Compiler = @import("compiler.zig");
const Environment = @import("environment.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const SymbolTable = @import("symbol_table.zig");
const VM = @import("vm.zig");

const object = @import("object.zig");

const PROMPT = ">> ";

pub fn start(allocator: std.mem.Allocator, in: *io.Reader, out: *io.Writer) !?void {
    const constants = std.ArrayList(object.Object).empty;
    const globals = try allocator.alloc(object.Object, VM.global_size);
    var symbol_table = SymbolTable.init(allocator);

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

        var compiler = try Compiler.initWithState(allocator, &symbol_table, constants);

        compiler.compile(arena.allocator(), .{ .program = program }) catch |err| {
            try out.print("Woops! Compilation failed\n {s}\n", .{@errorName(err)});
            try out.flush();
            continue;
        };

        var machine = try VM.initWithGlobalStore(allocator, compiler.bytecode(), globals);

        machine.run() catch |err| {
            try out.print("Woops! Executing bytecode failed\n {s}\n", .{@errorName(err)});
            try out.flush();
            continue;
        };

        const last_popped = machine.lastPoppedStackElem();

        const rendered = try last_popped.inspect(arena.allocator());

        try out.writeAll(rendered);
        try out.writeAll("\n");

        try out.flush();
    }
}
