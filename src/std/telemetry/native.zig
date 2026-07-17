const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");
const metrics = @import("../../telemetry/metrics.zig");

pub const specifier: [:0]const u8 = "std:telemetry/native";

const functions = [_]js_abi.Function{
    .{ .name = "registerMetricNative", .callback = js_registerMetricNative, .length = 1 },
    .{ .name = "addMetricNative", .callback = js_addMetricNative, .length = 2 },
    .{ .name = "setMetricNative", .callback = js_setMetricNative, .length = 2 },
    .{ .name = "observeMetricNative", .callback = js_observeMetricNative, .length = 2 },
    .{ .name = "metricValueNative", .callback = js_metricValueNative, .length = 1 },
    .{ .name = "snapshotMetricsNative", .callback = js_snapshotMetricsNative, .length = 0 },
    .{ .name = "clearMetricsNative", .callback = js_clearMetricsNative, .length = 0 },
    .{ .name = null, .callback = js_snapshotMetricsNative },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
    &functions[1],
    &functions[2],
    &functions[3],
    &functions[4],
    &functions[5],
    &functions[6],
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &function_ptrs);
}

fn throwType(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_type_error(ctx, message);
}

fn throwInternal(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_error(ctx, message);
}

fn missing(ctx: *js_abi.Context, value: js_abi.Value) bool {
    return ctx.api.is_undefined(ctx, value) != 0 or ctx.api.is_null(ctx, value) != 0;
}

fn stringFromValue(ctx: *js_abi.Context, value: js_abi.Value) ?[]const u8 {
    return std.mem.span(ctx.api.to_string(ctx, value) orelse return null);
}

fn stringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8) ?[]const u8 {
    const value = ctx.api.get_property(ctx, object, key);
    if (missing(ctx, value)) return null;
    return stringFromValue(ctx, value);
}

fn kindFromString(value: []const u8) ?metrics.Kind {
    if (std.mem.eql(u8, value, "counter")) return .counter;
    if (std.mem.eql(u8, value, "gauge")) return .gauge;
    if (std.mem.eql(u8, value, "histogram")) return .histogram;
    return null;
}

fn readId(ctx: *js_abi.Context, value: js_abi.Value) !metrics.Id {
    var raw: i32 = 0;
    if (ctx.api.to_int32(ctx, value, &raw) < 0 or raw < 0) return error.InvalidMetricId;
    return @intCast(raw);
}

fn readNumber(ctx: *js_abi.Context, value: js_abi.Value) !f64 {
    var raw: f64 = 0;
    if (ctx.api.to_float64(ctx, value, &raw) < 0) return error.InvalidMetricValue;
    return raw;
}

fn js_registerMetricNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1 or ctx.api.is_object(ctx, argv[0]) == 0) return throwType(ctx, "registerMetric requires a definition object");
    const scope = stringProp(ctx, argv[0], "scope") orelse return throwType(ctx, "metric scope must be a string");
    const name = stringProp(ctx, argv[0], "name") orelse return throwType(ctx, "metric name must be a string");
    const kind_text = stringProp(ctx, argv[0], "kind") orelse return throwType(ctx, "metric kind must be a string");
    const kind = kindFromString(kind_text) orelse return throwType(ctx, "metric kind must be counter, gauge, or histogram");
    const unit = stringProp(ctx, argv[0], "unit") orelse "";
    const id = metrics.register(.{ .scope = scope, .name = name, .kind = kind, .unit = unit }) catch return throwInternal(ctx, "failed to register metric");
    return ctx.api.int32_value(ctx, @intCast(id));
}

fn js_addMetricNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 2) return throwType(ctx, "addMetric requires id and delta");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "metric id must be a non-negative integer");
    const delta = readNumber(ctx, argv[1]) catch return throwType(ctx, "metric delta must be a number");
    metrics.add(id, delta) catch return throwInternal(ctx, "failed to add metric");
    return ctx.api.undefined(ctx);
}

fn js_setMetricNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 2) return throwType(ctx, "setMetric requires id and value");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "metric id must be a non-negative integer");
    const value = readNumber(ctx, argv[1]) catch return throwType(ctx, "metric value must be a number");
    metrics.set(id, value) catch return throwInternal(ctx, "failed to set metric");
    return ctx.api.undefined(ctx);
}

fn js_observeMetricNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 2) return throwType(ctx, "observeMetric requires id and value");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "metric id must be a non-negative integer");
    const value = readNumber(ctx, argv[1]) catch return throwType(ctx, "metric value must be a number");
    metrics.observe(id, value) catch return throwInternal(ctx, "failed to observe metric");
    return ctx.api.undefined(ctx);
}

fn js_metricValueNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "metricValue requires id");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "metric id must be a non-negative integer");
    const current = metrics.value(id) catch return throwInternal(ctx, "failed to read metric");
    return ctx.api.float64_value(ctx, current);
}

fn setStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: []const u8) !void {
    const value_z = try std.heap.page_allocator.dupeZ(u8, value);
    defer std.heap.page_allocator.free(value_z);
    if (ctx.api.set_property(ctx, object, key, ctx.api.string_value(ctx, value_z.ptr)) < 0) return error.JavaScriptError;
}

fn setNumberProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: f64) !void {
    if (ctx.api.set_property(ctx, object, key, ctx.api.float64_value(ctx, value)) < 0) return error.JavaScriptError;
}

fn setIntProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: u64) !void {
    if (ctx.api.set_property(ctx, object, key, ctx.api.float64_value(ctx, @floatFromInt(value))) < 0) return error.JavaScriptError;
}

fn kindName(kind: metrics.Kind) []const u8 {
    return switch (kind) {
        .counter => "counter",
        .gauge => "gauge",
        .histogram => "histogram",
    };
}

fn snapshotValue(ctx: *js_abi.Context, snapshot: metrics.Snapshot) !js_abi.Value {
    const out = ctx.api.object_value(ctx);
    if (ctx.api.set_property(ctx, out, "id", ctx.api.int32_value(ctx, @intCast(snapshot.id))) < 0) return error.JavaScriptError;
    try setStringProp(ctx, out, "scope", snapshot.scope);
    try setStringProp(ctx, out, "name", snapshot.name);
    try setStringProp(ctx, out, "kind", kindName(snapshot.kind));
    try setStringProp(ctx, out, "unit", snapshot.unit);
    try setNumberProp(ctx, out, "value", snapshot.value);
    try setIntProp(ctx, out, "count", snapshot.count);
    try setNumberProp(ctx, out, "sum", snapshot.sum);
    try setNumberProp(ctx, out, "min", snapshot.min);
    try setNumberProp(ctx, out, "max", snapshot.max);
    return out;
}

fn js_snapshotMetricsNative(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var buffer: [metrics.max_metrics]metrics.Snapshot = undefined;
    const view = metrics.snapshot(&buffer);
    const out = ctx.api.array_value(ctx);
    for (view, 0..) |entry, index| {
        const item = snapshotValue(ctx, entry) catch return throwInternal(ctx, "failed to create metric snapshot");
        if (ctx.api.array_set(ctx, out, @intCast(index), item) < 0) return throwInternal(ctx, "failed to create metric snapshot");
    }
    return out;
}

fn js_clearMetricsNative(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    metrics.clear();
    return ctx.api.undefined(ctx);
}

test "telemetry native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
