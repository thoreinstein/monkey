const std = @import("std");

const object = @import("object.zig");

const Self = @This();

store: std.StringHashMap(object.Object),
outer: ?*Self,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .store = std.StringHashMap(object.Object).init(allocator),
        .outer = null,
    };
}

pub fn initEnclosedEnvironment(allocator: std.mem.Allocator, outer: *Self) Self {
    var env = init(allocator);
    env.outer = outer;

    return env;
}

pub fn deinit(self: *Self) void {
    var it = self.store.keyIterator();
    while (it.next()) |key| self.store.allocator.free(key.*);
    self.store.deinit();
}

pub fn get(self: Self, name: []const u8) ?object.Object {
    if (self.store.get(name)) |o| return o;
    if (self.outer) |o| return o.get(name);

    return null;
}

pub fn set(self: *Self, name: []const u8, value: object.Object) !object.Object {
    const owned_name = try self.store.allocator.dupe(u8, name);
    try self.store.put(owned_name, value);
    return value;
}
