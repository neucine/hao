const std = @import("std");

pub const max_metrics = 512;
pub const Id = u32;

pub const Kind = enum(u32) {
    counter = 1,
    gauge = 2,
    histogram = 3,
};

pub const Definition = struct {
    scope: []const u8,
    name: []const u8,
    kind: Kind,
    unit: []const u8 = "",
};

pub const Snapshot = struct {
    id: Id,
    scope: []const u8,
    name: []const u8,
    kind: Kind,
    unit: []const u8,
    value: f64,
    count: u64,
    sum: f64,
    min: f64,
    max: f64,
};

const Entry = struct {
    definition: Definition,
    value: f64 = 0,
    count: u64 = 0,
    sum: f64 = 0,
    min: f64 = 0,
    max: f64 = 0,
};

const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
};

var registry = Registry{};
const alloc = std.heap.page_allocator;

fn validateIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    return std.mem.indexOfAny(u8, text, "\x00\r\n") == null;
}

fn sameDefinition(a: Definition, b: Definition) bool {
    return a.kind == b.kind and
        std.mem.eql(u8, a.scope, b.scope) and
        std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.unit, b.unit);
}

fn ownedDefinition(definition: Definition) !Definition {
    return .{
        .scope = try alloc.dupe(u8, definition.scope),
        .name = try alloc.dupe(u8, definition.name),
        .kind = definition.kind,
        .unit = try alloc.dupe(u8, definition.unit),
    };
}

fn freeDefinition(definition: Definition) void {
    alloc.free(definition.scope);
    alloc.free(definition.name);
    alloc.free(definition.unit);
}

pub fn register(definition: Definition) !Id {
    if (!validateIdentifier(definition.scope)) return error.InvalidMetricScope;
    if (!validateIdentifier(definition.name)) return error.InvalidMetricName;
    if (std.mem.indexOfAny(u8, definition.unit, "\x00\r\n") != null) return error.InvalidMetricUnit;

    for (registry.entries.items, 0..) |entry, index| {
        if (sameDefinition(entry.definition, definition)) return @intCast(index);
    }

    if (registry.entries.items.len >= max_metrics) return error.TooManyMetrics;
    const owned = try ownedDefinition(definition);
    errdefer freeDefinition(owned);
    try registry.entries.append(alloc, .{ .definition = owned });
    return @intCast(registry.entries.items.len - 1);
}

fn entryFor(id: Id) ?*Entry {
    const index: usize = @intCast(id);
    if (index >= registry.entries.items.len) return null;
    return &registry.entries.items[index];
}

pub fn add(id: Id, delta: f64) !void {
    const entry = entryFor(id) orelse return error.UnknownMetric;
    switch (entry.definition.kind) {
        .counter => {
            if (delta < 0) return error.InvalidMetricOperation;
            entry.value += delta;
        },
        .gauge => entry.value += delta,
        .histogram => return error.InvalidMetricOperation,
    }
}

pub fn set(id: Id, new_value: f64) !void {
    const entry = entryFor(id) orelse return error.UnknownMetric;
    switch (entry.definition.kind) {
        .gauge => entry.value = new_value,
        .counter, .histogram => return error.InvalidMetricOperation,
    }
}

pub fn observe(id: Id, sample: f64) !void {
    const entry = entryFor(id) orelse return error.UnknownMetric;
    if (entry.definition.kind != .histogram) return error.InvalidMetricOperation;
    entry.count += 1;
    entry.sum += sample;
    if (entry.count == 1) {
        entry.min = sample;
        entry.max = sample;
    } else {
        entry.min = @min(entry.min, sample);
        entry.max = @max(entry.max, sample);
    }
}

pub fn value(id: Id) !f64 {
    const entry = entryFor(id) orelse return error.UnknownMetric;
    return switch (entry.definition.kind) {
        .counter, .gauge => entry.value,
        .histogram => @floatFromInt(entry.count),
    };
}

pub fn snapshot(buffer: []Snapshot) []const Snapshot {
    const count = @min(buffer.len, registry.entries.items.len);
    for (buffer[0..count], registry.entries.items[0..count], 0..) |*out, entry, index| {
        out.* = .{
            .id = @intCast(index),
            .scope = entry.definition.scope,
            .name = entry.definition.name,
            .kind = entry.definition.kind,
            .unit = entry.definition.unit,
            .value = entry.value,
            .count = entry.count,
            .sum = entry.sum,
            .min = entry.min,
            .max = entry.max,
        };
    }
    return buffer[0..count];
}

pub fn clear() void {
    for (registry.entries.items) |entry| freeDefinition(entry.definition);
    registry.entries.clearAndFree(alloc);
}

test "metrics register idempotently and snapshot" {
    clear();
    defer clear();

    const id = try register(.{ .scope = "test.runtime", .name = "requests", .kind = .counter, .unit = "count" });
    const same = try register(.{ .scope = "test.runtime", .name = "requests", .kind = .counter, .unit = "count" });
    try std.testing.expectEqual(id, same);
    try add(id, 2);

    var buffer: [max_metrics]Snapshot = undefined;
    const view = snapshot(&buffer);
    try std.testing.expectEqual(@as(usize, 1), view.len);
    try std.testing.expectEqualStrings("test.runtime", view[0].scope);
    try std.testing.expectEqualStrings("requests", view[0].name);
    try std.testing.expectEqual(Kind.counter, view[0].kind);
    try std.testing.expectEqual(@as(f64, 2), view[0].value);
}

test "histogram observes count sum and bounds" {
    clear();
    defer clear();

    const id = try register(.{ .scope = "test.latency", .name = "request_ms", .kind = .histogram, .unit = "ms" });
    try observe(id, 12);
    try observe(id, 8);
    try observe(id, 20);

    var buffer: [max_metrics]Snapshot = undefined;
    const view = snapshot(&buffer);
    try std.testing.expectEqual(@as(u64, 3), view[0].count);
    try std.testing.expectEqual(@as(f64, 40), view[0].sum);
    try std.testing.expectEqual(@as(f64, 8), view[0].min);
    try std.testing.expectEqual(@as(f64, 20), view[0].max);
}
