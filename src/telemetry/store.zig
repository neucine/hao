const std = @import("std");
const trace = @import("trace.zig");
const runtime_allocator = @import("../runtime_allocator.zig");

pub const max_trace_records = 512;

var trace_storage: [max_trace_records]trace.RecordSlot = undefined;
var trace_buffer = trace.Buffer.init(&trace_storage);
var trace_tracer = trace.Tracer.init(&trace_buffer, 0x7e1e7);
var next_span_id: u32 = 1;
var spans: std.AutoHashMapUnmanaged(u32, trace.Span) = .empty;
var next_scope_id: u32 = 1;
var scopes: std.AutoHashMapUnmanaged(u32, trace.Context) = .empty;

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn buffer() *trace.Buffer {
    return &trace_buffer;
}

pub fn tracer() *trace.Tracer {
    return &trace_tracer;
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
