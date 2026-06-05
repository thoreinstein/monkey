const std = @import("std");

const object = @import("object.zig");

pub const Builtin = struct {
    name: []const u8,
    builtin: object.Builtin,
};

pub const builtins = [_]Builtin{
    .{ .name = "len", .builtin = .{ .func = lenBuiltin } },
    .{ .name = "puts", .builtin = .{ .func = putsBuiltin } },
    .{ .name = "first", .builtin = .{ .func = firstBuiltin } },
    .{ .name = "last", .builtin = .{ .func = lastBuiltin } },
    .{ .name = "rest", .builtin = .{ .func = restBuiltin } },
    .{ .name = "push", .builtin = .{ .func = pushBuiltin } },
};

pub fn getByName(name: []const u8) ?object.Builtin {
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b.name)) return b.builtin;
    }

    return null;
}

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
        .array => |a| {
            if (a.elements.items.len > 0) return a.elements.items[0];
            return null;
        },
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
        .array => |a| {
            if (a.elements.items.len > 0) return a.elements.getLast();
            return null;
        },
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
            if (a.elements.items.len > 0) {
                const tail = a.elements.items[1..];

                var new_list = std.ArrayList(object.Object).empty;
                try new_list.appendSlice(allocator, tail);

                const array = try allocator.create(object.Array);
                array.* = .{ .elements = new_list };

                return .{ .array = array };
            }

            return null;
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

            const array = try allocator.create(object.Array);
            array.* = .{ .elements = new_list };

            return .{ .array = array };
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
