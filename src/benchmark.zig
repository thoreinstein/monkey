const std = @import("std");

const Compiler = @import("compiler.zig");
const Environment = @import("environment.zig");
const Evaluator = @import("evaluator.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");
const VM = @import("vm.zig");

const input =
    \\let fibonacci = fn(x) {
    \\  if (x == 0) { 0 } else {
    \\    if (x == 1) { 1 } else {
    \\      fibonacci(x - 1) + fibonacci(x - 2);
    \\    }
    \\  }
    \\};
    \\fibonacci(35);
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = init.io;

    // --- compiler + VM ---
    {
        const lexer = Lexer.init(input);
        var parser = try Parser.init(allocator, lexer);
        const program = try parser.parseProgram() orelse return error.ParseFailed;

        var compiler = try Compiler.init(allocator);
        try compiler.compile(allocator, .{ .program = program });
        var machine = try VM.init(allocator, compiler.bytecode());

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        try machine.run();
        const end = std.Io.Clock.Timestamp.now(io, .awake);

        const result = machine.lastPoppedStackElem();
        const elapsed_ms = start.durationTo(end).raw.toMilliseconds();

        std.debug.print("engine=vm,   result={s}, duration={d}ms\n", .{ try result.inspect(allocator), elapsed_ms });
    }

    // --- tree-walking interpreter ---
    {
        const lexer = Lexer.init(input);
        var parser = try Parser.init(allocator, lexer);
        const program = try parser.parseProgram() orelse return error.ParseFailed;

        var env = Environment.init(allocator);

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const result = try Evaluator.eval(allocator, .{ .program = program }, &env) orelse return error.NoResult;
        const end = std.Io.Clock.Timestamp.now(io, .awake);

        const elapsed_ms = start.durationTo(end).raw.toMilliseconds();

        std.debug.print("engine=eval, result={s}, duration={d}ms\n", .{ try result.inspect(allocator), elapsed_ms });
    }
}
