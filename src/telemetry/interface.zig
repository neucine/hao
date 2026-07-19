const shared = @import("zig_libs").telemetry;
const std = @import("std");
const metrics = @import("metrics.zig");
const store = @import("store.zig");
const trace = @import("trace.zig");

pub const MetricKind = shared.MetricKind;
pub const MetricUnit = shared.MetricUnit;
pub const MetricDefinition = shared.MetricDefinition;
pub const TraceId = shared.TraceId;
pub const SpanId = shared.SpanId;
pub const TraceStatus = shared.TraceStatus;
pub const SpanKind = shared.SpanKind;
pub const AttributeValue = shared.AttributeValue;
pub const Attribute = shared.Attribute;
pub const TraceContext = shared.TraceContext;
pub const SpanHandle = shared.SpanHandle;
pub const Backend = shared.Backend;
pub const Scope = shared.Scope;

const host_allocator = std.heap.page_allocator;
var host_context: u8 = 0;

fn metricKind(kind: MetricKind) metrics.Kind {
    return switch (kind) {
        .counter => .counter,
        .gauge => .gauge,
    };
}

fn metricId(definition: MetricDefinition) !metrics.Id {
    return metrics.register(.{
        .scope = definition.group,
        .name = definition.name,
        .kind = metricKind(definition.kind),
        .unit = switch (definition.unit) {
            .count => "count",
            .bytes => "bytes",
            .nanoseconds => "nanoseconds",
        },
    });
}

fn hostMetricAdd(_: *anyopaque, definition: MetricDefinition, delta: i64) void {
    const id = metricId(definition) catch return;
    metrics.add(id, @floatFromInt(delta)) catch {};
}

fn hostMetricSet(_: *anyopaque, definition: MetricDefinition, value: i64) void {
    const id = metricId(definition) catch return;
    metrics.set(id, @floatFromInt(value)) catch {};
}

fn hostStartSpan(
    _: *anyopaque,
    parent: TraceContext,
    timestamp_ns: i128,
    name: []const u8,
    kind: SpanKind,
    attributes: []const Attribute,
) SpanHandle {
    const created = store.tracer().startSpanWithParent(parent, timestamp_ns, name, kind, attributes) catch return .{};
    const owned = host_allocator.create(trace.Span) catch return .{};
    owned.* = created;
    return .{ .id = @intFromPtr(owned), .context = owned.contextValue() };
}

fn hostSpan(handle: usize) ?*trace.Span {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

fn hostAddEvent(_: *anyopaque, handle: usize, timestamp_ns: i128, name: []const u8, attributes: []const Attribute) void {
    const span = hostSpan(handle) orelse return;
    span.addEvent(timestamp_ns, name, attributes) catch {};
}

fn hostEndSpan(_: *anyopaque, handle: usize, timestamp_ns: i128, status: TraceStatus) void {
    const span = hostSpan(handle) orelse return;
    span.end(timestamp_ns, status) catch {};
    host_allocator.destroy(span);
}

const host_vtable = Backend.VTable{
    .metric_add = hostMetricAdd,
    .metric_set = hostMetricSet,
    .start_span = hostStartSpan,
    .add_event = hostAddEvent,
    .end_span = hostEndSpan,
};

pub fn host() Backend {
    return .{ .context = &host_context, .vtable = &host_vtable };
}
