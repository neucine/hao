const std = @import("std");
const trace = @import("trace.zig");
const runtime_allocator = @import("../runtime_allocator.zig");

pub const max_trace_records = 1_048_576;

var trace_storage: []trace.RecordSlot = &.{};
var trace_buffer = trace.Buffer.init(&.{});
var trace_tracer = trace.Tracer.init(&trace_buffer, 0x7e1e7);
var next_span_id: u32 = 1;
var spans: std.AutoHashMapUnmanaged(u32, trace.Span) = .empty;
var next_scope_id: u32 = 1;
var scopes: std.AutoHashMapUnmanaged(u32, trace.Context) = .empty;

fn nanoTimestamp() i128 {
    return @import("../time_compat.zig").monotonicNanoseconds();
}

pub fn buffer() *trace.Buffer {
    return &trace_buffer;
}

pub fn capacity() usize {
    return trace_storage.len;
}

pub fn tracer() *trace.Tracer {
    return &trace_tracer;
}

pub fn init(allocator: std.mem.Allocator, trace_capacity: usize) !void {
    if (trace_storage.len != 0) return error.TelemetryStoreAlreadyInitialized;
    if (trace_capacity == 0) {
        trace_tracer.policy = .{ .sample = trace.neverSample };
        return;
    }
    if (trace_capacity > max_trace_records) return error.TelemetryTraceLimitExceeded;
    trace_storage = try allocator.alloc(trace.RecordSlot, trace_capacity);
    trace_buffer = trace.Buffer.init(trace_storage);
    trace_tracer = trace.Tracer.init(&trace_buffer, 0x7e1e7);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (trace_storage.len != 0) allocator.free(trace_storage);
    trace_storage = &.{};
    trace_buffer = trace.Buffer.init(&.{});
    trace_tracer = trace.Tracer.init(&trace_buffer, 0x7e1e7);
    spans.deinit(allocator);
    spans = .empty;
    scopes.deinit(allocator);
    scopes = .empty;
    next_span_id = 1;
    next_scope_id = 1;
}

pub fn startSpan(name: []const u8) !u32 {
    const previous = trace.currentContext();
    const span = try trace_tracer.startSpan(nanoTimestamp(), name, .internal, &.{});
    const id = next_span_id;
    next_span_id +%= 1;
    if (next_span_id == 0) next_span_id = 1;
    spans.put(runtime_allocator.allocator(), id, span) catch |err| {
        _ = trace.setCurrentContext(previous);
        return err;
    };
    return id;
}

pub fn startRootSpan(name: []const u8) !u32 {
    const previous = trace.currentContext();
    _ = trace.setCurrentContext(trace.Context.root);
    defer _ = trace.setCurrentContext(previous);
    const span = try trace_tracer.startSpan(nanoTimestamp(), name, .internal, &.{});
    const id = next_span_id;
    next_span_id +%= 1;
    if (next_span_id == 0) next_span_id = 1;
    spans.put(runtime_allocator.allocator(), id, span) catch return error.OutOfMemory;
    return id;
}

pub fn enterSpan(id: u32) !u32 {
    const span = spans.get(id) orelse return error.UnknownSpan;
    const previous = trace.setCurrentContext(span.contextValue());
    const scope_id = next_scope_id;
    next_scope_id +%= 1;
    if (next_scope_id == 0) next_scope_id = 1;
    scopes.put(runtime_allocator.allocator(), scope_id, previous) catch |err| {
        _ = trace.setCurrentContext(previous);
        return err;
    };
    return scope_id;
}

pub fn exitSpan(scope_id: u32) !void {
    const previous = scopes.fetchRemove(scope_id) orelse return error.UnknownSpanScope;
    _ = trace.setCurrentContext(previous.value);
}

pub fn endSpan(id: u32, status: trace.Status) !void {
    const entry = spans.fetchRemove(id) orelse return error.UnknownSpan;
    var span = entry.value;
    try span.end(nanoTimestamp(), status);
}

pub fn clear() void {
    spans.deinit(runtime_allocator.allocator());
    spans = .empty;
    scopes.deinit(runtime_allocator.allocator());
    scopes = .empty;
    next_span_id = 1;
    next_scope_id = 1;
    trace_buffer.clear();
}

test "telemetry store initializes configured capacity and rejects duplicate or oversized rings" {
    try std.testing.expectError(
        error.TelemetryTraceLimitExceeded,
        init(std.testing.allocator, max_trace_records + 1),
    );

    try init(std.testing.allocator, 3);
    defer deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), capacity());
    try std.testing.expectError(
        error.TelemetryStoreAlreadyInitialized,
        init(std.testing.allocator, 4),
    );
}

test "telemetry store supports disabled traces and clean reuse" {
    runtime_allocator.init(std.testing.allocator);
    defer runtime_allocator.init(std.heap.page_allocator);

    try init(std.testing.allocator, 0);
    defer deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), capacity());
    const disabled_id = try startSpan("disabled");
    try endSpan(disabled_id, .ok);
    try std.testing.expectEqual(@as(usize, 0), buffer().len());

    deinit(std.testing.allocator);
    try init(std.testing.allocator, 2);

    const first_id = try startSpan("first");
    try std.testing.expectEqual(@as(u32, 1), first_id);
    try endSpan(first_id, .ok);
    try std.testing.expectEqual(@as(usize, 2), buffer().len());

    deinit(std.testing.allocator);
    try init(std.testing.allocator, 2);

    const restarted_id = try startSpan("restarted");
    try std.testing.expectEqual(@as(u32, 1), restarted_id);
    try endSpan(restarted_id, .ok);
    try std.testing.expectEqual(@as(usize, 2), buffer().len());
}
