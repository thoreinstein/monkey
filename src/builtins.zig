const std = @import("std");

const object = @import("object.zig");

pub const builtins = std.StaticStringMap(object.Builtin).initComptime(.{
    .{ "len", object.Builtin{ .func = lenBuiltin } },
    .{ "first", object.Builtin{ .func = firstBuiltin } },
    .{ "last", object.Builtin{ .func = lastBuiltin } },
    .{ "rest", object.Builtin{ .func = restBuiltin } },
    .{ "push", object.Builtin{ .func = pushBuiltin } },
    .{ "puts", object.Builtin{ .func = putsBuiltin } },
});

fn lenBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    if (args.len != 1) {
        const msg = try std.fmt.allocPrint(allocator, "wrong number of arguments. got={d}, want=1", .{args.len});
        return .{ .error_ = .{ .message = msg } };
    }

    switch (args[0]) {
        .string => |s| {
            const size: i64 = @intCast(s.value.len);

            return .{ .integer = .{ .value = size } };
        },
        .array => |a| {
            const size: i64 = @intCast(a.elements.items.len);

            return .{ .integer = .{ .value = size } };
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "argument to `len` not supported, got={s}", .{args[0].kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }

    return .{ .null_ = .{} };
}

fn firstBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    if (args.len != 1) {
        const msg = try std.fmt.allocPrint(allocator, "wrong number of arguments. got={d}, want=1", .{args.len});
        return .{ .error_ = .{ .message = msg } };
    }

    switch (args[0]) {
        .array => |a| return a.elements.items[0],

        else => {
            const msg = try std.fmt.allocPrint(allocator, "argument to `first` must be ARRAY, got={s}", .{args[0].kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }

    return .{ .null_ = .{} };
}

fn lastBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    if (args.len != 1) {
        const msg = try std.fmt.allocPrint(allocator, "wrong number of arguments. got={d}, want=1", .{args.len});
        return .{ .error_ = .{ .message = msg } };
    }

    switch (args[0]) {
        .array => |a| return a.elements.getLast(),

        else => {
            const msg = try std.fmt.allocPrint(allocator, "argument to `last` must be ARRAY, got={s}", .{args[0].kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }

    return .{ .null_ = .{} };
}

fn restBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    if (args.len != 1) {
        const msg = try std.fmt.allocPrint(allocator, "wrong number of arguments. got={d}, want=1", .{args.len});
        return .{ .error_ = .{ .message = msg } };
    }

    switch (args[0]) {
        .array => |a| {
            const tail = a.elements.items[1..];

            var new_list = std.ArrayList(object.Object).empty;
            try new_list.appendSlice(allocator, tail);

            return .{ .array = .{ .elements = new_list } };
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "argument to `rest` must be ARRAY, got={s}", .{args[0].kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }

    return .{ .null_ = .{} };
}

fn pushBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    if (args.len != 2) {
        const msg = try std.fmt.allocPrint(allocator, "wrong number of arguments. got={d}, want=2", .{args.len});
        return .{ .error_ = .{ .message = msg } };
    }

    switch (args[0]) {
        .array => |a| {
            var new_list = std.ArrayList(object.Object).empty;
            try new_list.appendSlice(allocator, a.elements.items);
            try new_list.append(allocator, args[1]);

            return .{ .array = .{ .elements = new_list } };
        },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "argument to `first` must be ARRAY, got={s}", .{args[0].kind()});
            return .{ .error_ = .{ .message = msg } };
        },
    }

    return .{ .null_ = .{} };
}

fn putsBuiltin(allocator: std.mem.Allocator, args: []const object.Object) !?object.Object {
    for (args) |arg| {
        const val = arg.inspect(allocator) catch return error.OutOfMemory;

        std.debug.print("{s}\n", .{val});
    }

    return .{ .null_ = .{} };
}
