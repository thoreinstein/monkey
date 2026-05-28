const std = @import("std");

const object = @import("object.zig");

pub const builtins = std.StaticStringMap(object.Builtin).initComptime(.{
    .{ "len", object.Builtin{ .func = lenBuiltin } },
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
