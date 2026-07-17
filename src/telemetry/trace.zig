const std = @import("std");

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const max_name_bytes = 96;
pub const max_attributes = 16;
pub const max_attribute_key_bytes = 64;
pub const max_attribute_string_bytes = 256;

pub const Status = enum(u8) {
    unset,
    ok,
    err,
};

pub const Kind = enum(u8) {
    internal,
    server,
    client,
    producer,
    consumer,
};

pub const AttributeValue = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
};

pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

pub const Context = struct {
    trace_id: TraceId,
    span_id: SpanId,
    sampled: bool = true,

    pub const root = Context{
        .trace_id = [_]u8{0} ** 16,
        .span_id = [_]u8{0} ** 8,
        .sampled = true,
    };

    pub fn isRoot(self: Context) bool {
        return std.mem.eql(u8, &self.trace_id, &root.trace_id) and
            std.mem.eql(u8, &self.span_id, &root.span_id);
    }
};

pub const RecordKind = enum(u8) {
    span_start,
    event,
    span_end,
};

pub const Record = struct {
    sequence: u64 = 0,
    kind: RecordKind = .event,
    timestamp_ns: i128 = 0,
    context: Context = Context.root,
    parent_span_id: SpanId = [_]u8{0} ** 8,
    name: []const u8 = "",
    span_kind: Kind = .internal,
    status: Status = .unset,
    attributes: []const Attribute = &.{},
};

pub const RecordView = struct {
    sequence: u64,
    kind: RecordKind,
    timestamp_ns: i128,
    context: Context,
    parent_span_id: SpanId,
    name: []const u8,
    span_kind: Kind,
    status: Status,
    attributes: []const StoredAttribute,
};

pub const CursorSnapshot = struct {
    records: []const RecordView,
    next_cursor: u64,
    missed: bool,
};

pub const SamplingFn = *const fn (userdata: ?*anyopaque, parent: Context) bool;

pub const Policy = struct {
    sample: SamplingFn = alwaysSample,
    userdata: ?*anyopaque = null,
};

pub const Buffer = struct {
    storage: []RecordSlot,
    next: usize = 0,
    length: usize = 0,
    dropped: u64 = 0,
    next_sequence: u64 = 1,

    pub fn init(storage: []RecordSlot) Buffer {
        return .{ .storage = storage };
    }

    fn append(self: *Buffer, record: Record) !void {
        if (self.storage.len == 0) return error.TraceBufferUnavailable;

        var slot = &self.storage[self.next];
        try slot.copyFrom(record);
        slot.sequence = self.next_sequence;
        self.next_sequence += 1;
        self.next = (self.next + 1) % self.storage.len;
        if (self.length < self.storage.len) {
            self.length += 1;
        } else {
            self.dropped += 1;
        }
    }

    pub fn len(self: *const Buffer) usize {
        return self.length;
    }

    pub fn droppedCount(self: *const Buffer) u64 {
        return self.dropped;
    }

    pub fn clear(self: *Buffer) void {
        self.next = 0;
        self.length = 0;
        self.dropped = 0;
        self.next_sequence = 1;
    }

    pub fn snapshot(self: *const Buffer, output: []RecordView) []const RecordView {
        const count = @min(output.len, self.length);
        if (count == 0) return output[0..0];

        const start = if (self.length == self.storage.len) self.next else 0;
        for (0..count) |index| {
            const source = &self.storage[(start + index) % self.storage.len];
            output[index] = source.view();
        }
        return output[0..count];
    }

    pub fn snapshotAfter(self: *const Buffer, cursor: u64, output: []RecordView) CursorSnapshot {
        const latest = self.next_sequence - 1;
        if (self.length == 0 or cursor >= latest) {
            return .{ .records = output[0..0], .next_cursor = latest, .missed = false };
        }

        const oldest = latest - self.length + 1;
        const missed = cursor + 1 < oldest;
        const first = if (missed) oldest else cursor + 1;
        const available = latest - first + 1;
        const count = @min(output.len, available);
        if (count == 0) {
            return .{ .records = output[0..0], .next_cursor = cursor, .missed = missed };
        }
        const start = if (self.length == self.storage.len) self.next else 0;
        for (0..count) |index| {
            const sequence = first + index;
            const offset = sequence - oldest;
            const source = &self.storage[(start + offset) % self.storage.len];
            output[index] = source.view();
        }
        return .{
            .records = output[0..count],
            .next_cursor = first + count - 1,
            .missed = missed,
        };
    }
};

pub const RecordSlot = struct {
    sequence: u64 = 0,
    kind: RecordKind = .event,
    timestamp_ns: i128 = 0,
    context: Context = Context.root,
    parent_span_id: SpanId = [_]u8{0} ** 8,
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    span_kind: Kind = .internal,
    status: Status = .unset,
    attributes: [max_attributes]StoredAttribute = undefined,
    attribute_count: usize = 0,

    fn copyFrom(self: *RecordSlot, record: Record) !void {
        if (record.name.len > max_name_bytes) return error.TraceNameTooLong;
        if (record.attributes.len > max_attributes) return error.TooManyTraceAttributes;

        self.kind = record.kind;
        self.timestamp_ns = record.timestamp_ns;
        self.context = record.context;
        self.parent_span_id = record.parent_span_id;
        self.name_len = record.name.len;
        @memcpy(self.name[0..record.name.len], record.name);
        self.span_kind = record.span_kind;
        self.status = record.status;
        self.attribute_count = record.attributes.len;
        for (self.attributes[0..record.attributes.len], record.attributes) |*stored, attribute| {
            try stored.copyFrom(attribute);
        }
    }

    fn view(self: *const RecordSlot) RecordView {
        return .{
            .sequence = self.sequence,
            .kind = self.kind,
            .timestamp_ns = self.timestamp_ns,
            .context = self.context,
            .parent_span_id = self.parent_span_id,
            .name = self.name[0..self.name_len],
            .span_kind = self.span_kind,
            .status = self.status,
            .attributes = self.attributes[0..self.attribute_count],
        };
    }
};

pub const StoredAttribute = struct {
    key: [max_attribute_key_bytes]u8 = undefined,
    key_len: usize = 0,
    value: StoredValue = .{ .boolean = false },

    fn copyFrom(self: *StoredAttribute, attribute: Attribute) !void {
        if (attribute.key.len > max_attribute_key_bytes) return error.TraceAttributeKeyTooLong;
        self.key_len = attribute.key.len;
        @memcpy(self.key[0..attribute.key.len], attribute.key);
        self.value = switch (attribute.value) {
            .boolean => |value| .{ .boolean = value },
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
            .string => |value| blk: {
                if (value.len > max_attribute_string_bytes) return error.TraceAttributeValueTooLong;
                var bytes = [_]u8{0} ** max_attribute_string_bytes;
                @memcpy(bytes[0..value.len], value);
                break :blk .{ .string = .{ .bytes = bytes, .len = value.len } };
            },
        };
    }
};

pub const StoredValue = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: struct {
        bytes: [max_attribute_string_bytes]u8,
        len: usize,
    },
};

pub const Tracer = struct {
    buffer: *Buffer,
    policy: Policy = .{},
    random: std.Random.DefaultPrng,

    pub fn init(buffer: *Buffer, seed: u64) Tracer {
        return .{ .buffer = buffer, .random = std.Random.DefaultPrng.init(seed) };
    }

    pub fn startSpan(
        self: *Tracer,
        parent: Context,
        timestamp_ns: i128,
        name: []const u8,
        kind: Kind,
        attributes: []const Attribute,
    ) !Span {
        if (name.len > max_name_bytes) return error.TraceNameTooLong;
        const sampled = if (!parent.isRoot() and !parent.sampled)
            false
        else
            self.policy.sample(self.policy.userdata, parent);
        var trace_id: TraceId = undefined;
        var span_id: SpanId = undefined;
        self.random.random().bytes(&trace_id);
        self.random.random().bytes(&span_id);
        var context = Context{
            .trace_id = trace_id,
            .span_id = span_id,
            .sampled = sampled,
        };
        if (parent.isRoot()) {
            // A root span starts a new trace.
        } else {
            context.trace_id = parent.trace_id;
        }

        if (sampled) {
            try self.buffer.append(.{
                .kind = .span_start,
                .timestamp_ns = timestamp_ns,
                .context = context,
                .parent_span_id = if (parent.isRoot()) [_]u8{0} ** 8 else parent.span_id,
                .name = name,
                .span_kind = kind,
                .attributes = attributes,
            });
        }
        var span_name = [_]u8{0} ** max_name_bytes;
        @memcpy(span_name[0..name.len], name);
        return .{
            .tracer = self,
            .context = context,
            .name = span_name,
            .name_len = name.len,
            .sampled = sampled,
        };
    }
};

pub const Span = struct {
    tracer: *Tracer,
    context: Context,
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    sampled: bool,
    ended: bool = false,

    pub fn contextValue(self: *const Span) Context {
        return self.context;
    }

    pub fn addEvent(self: *Span, timestamp_ns: i128, name: []const u8, attributes: []const Attribute) !void {
        if (self.ended) return error.TraceSpanEnded;
        if (!self.sampled) return;
        try self.tracer.buffer.append(.{
            .kind = .event,
            .timestamp_ns = timestamp_ns,
            .context = self.context,
            .name = name,
            .attributes = attributes,
        });
    }

    pub fn end(self: *Span, timestamp_ns: i128, status: Status) !void {
        if (self.ended) return error.TraceSpanEnded;
        self.ended = true;
        if (!self.sampled) return;
        try self.tracer.buffer.append(.{
            .kind = .span_end,
            .timestamp_ns = timestamp_ns,
            .context = self.context,
            .name = self.name[0..self.name_len],
            .status = status,
        });
    }
};

pub fn alwaysSample(_: ?*anyopaque, _: Context) bool {
    return true;
}

pub fn neverSample(_: ?*anyopaque, _: Context) bool {
    return false;
}

test "tracer records a span and its events in order" {
    var storage: [8]RecordSlot = undefined;
    var buffer = Buffer.init(&storage);
    var tracer = Tracer.init(&buffer, 1);

    var span = try tracer.startSpan(Context.root, 10, "request", .server, &.{});
    try span.addEvent(20, "headers", &.{});
    try span.end(30, .ok);

    var output: [8]RecordView = undefined;
    const records = buffer.snapshot(&output);
    try std.testing.expectEqual(@as(usize, 3), records.len);
    try std.testing.expectEqual(RecordKind.span_start, records[0].kind);
    try std.testing.expectEqual(@as(u64, 1), records[0].sequence);
    try std.testing.expectEqual(RecordKind.event, records[1].kind);
    try std.testing.expectEqual(RecordKind.span_end, records[2].kind);
    try std.testing.expectEqual(@as(u64, 3), records[2].sequence);
    try std.testing.expectEqual(@as(i128, 30), records[2].timestamp_ns);
    try std.testing.expectEqual(Status.ok, records[2].status);
    try std.testing.expectEqual(span.contextValue().trace_id, records[0].context.trace_id);
    try std.testing.expectEqual(span.contextValue().trace_id, records[2].context.trace_id);
}

test "ring buffer keeps the newest records and counts overflow" {
    var storage: [1]RecordSlot = undefined;
    var buffer = Buffer.init(&storage);
    var tracer = Tracer.init(&buffer, 2);

    var span = try tracer.startSpan(Context.root, 1, "one", .internal, &.{});
    try span.end(2, .ok);
    try std.testing.expectEqual(@as(usize, 1), buffer.len());
    try std.testing.expectEqual(@as(u64, 1), buffer.droppedCount());

    var output: [1]RecordView = undefined;
    const records = buffer.snapshot(&output);
    try std.testing.expectEqual(@as(i128, 2), records[0].timestamp_ns);
    try std.testing.expectEqual(RecordKind.span_end, records[0].kind);
}

test "unsampled spans do not write records" {
    var storage: [2]RecordSlot = undefined;
    var buffer = Buffer.init(&storage);
    var tracer = Tracer.init(&buffer, 3);
    tracer.policy = .{ .sample = neverSample };

    var span = try tracer.startSpan(Context.root, 1, "ignored", .internal, &.{});
    try span.addEvent(2, "ignored", &.{});
    try span.end(3, .ok);
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
}

test "trace buffer supports incremental cursors and reports gaps" {
    var storage: [3]RecordSlot = undefined;
    var buffer = Buffer.init(&storage);
    var tracer = Tracer.init(&buffer, 5);

    var first = try tracer.startSpan(Context.root, 1, "first", .internal, &.{});
    try first.end(2, .ok);
    var second = try tracer.startSpan(Context.root, 3, "second", .internal, &.{});
    try second.end(4, .ok);

    var output: [2]RecordView = undefined;
    var page = buffer.snapshotAfter(2, &output);
    try std.testing.expect(!page.missed);
    try std.testing.expectEqual(@as(usize, 2), page.records.len);
    try std.testing.expectEqual(@as(u64, 3), page.records[0].sequence);
    try std.testing.expectEqual(@as(u64, 4), page.next_cursor);

    page = buffer.snapshotAfter(0, &output);
    try std.testing.expect(page.missed);
    try std.testing.expectEqual(@as(u64, 2), page.records[0].sequence);
    try std.testing.expectEqual(@as(u64, 3), page.next_cursor);
}

test "records own attribute strings and preserve parent context" {
    var storage: [8]RecordSlot = undefined;
    var buffer = Buffer.init(&storage);
    var tracer = Tracer.init(&buffer, 4);
    const attributes = [_]Attribute{
        .{ .key = "http.method", .value = .{ .string = "GET" } },
        .{ .key = "retry", .value = .{ .integer = 2 } },
    };

    var parent = try tracer.startSpan(Context.root, 1, "request", .server, &attributes);
    var child = try tracer.startSpan(parent.contextValue(), 2, "backend", .client, &.{});
    try child.end(3, .ok);
    try parent.end(4, .ok);

    var output: [8]RecordView = undefined;
    const records = buffer.snapshot(&output);
    try std.testing.expectEqual(@as(usize, 4), records.len);
    try std.testing.expectEqual(parent.contextValue().span_id, records[1].parent_span_id);
    try std.testing.expectEqualStrings("http.method", records[0].attributes[0].key[0..records[0].attributes[0].key_len]);
    try std.testing.expectEqual(StoredValue{ .string = .{ .bytes = [_]u8{ 'G', 'E', 'T' } ++ [_]u8{0} ** (max_attribute_string_bytes - 3), .len = 3 } }, records[0].attributes[0].value);
}
