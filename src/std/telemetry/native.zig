const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs_test = @import("../../qjs.zig");
const runtime_allocator = @import("../../runtime_allocator.zig");
const process_memory = @import("../../process_memory.zig");
const metrics = @import("../../telemetry/metrics.zig");
const store = @import("../../telemetry/store.zig");
const trace = @import("../../telemetry/trace.zig");

var peak_resident_bytes = std.atomic.Value(u64).init(0);
var peak_physical_footprint_bytes = std.atomic.Value(u64).init(0);

pub const specifier: [:0]const u8 = "std:telemetry/native";

fn allocator() std.mem.Allocator {
    return runtime_allocator.allocator();
}

const functions = [_]js_abi.Function{
    .{ .name = "registerMetricNative", .callback = js_registerMetricNative, .length = 1 },
    .{ .name = "addMetricNative", .callback = js_addMetricNative, .length = 2 },
    .{ .name = "setMetricNative", .callback = js_setMetricNative, .length = 2 },
    .{ .name = "observeMetricNative", .callback = js_observeMetricNative, .length = 2 },
    .{ .name = "metricValueNative", .callback = js_metricValueNative, .length = 1 },
    .{ .name = "snapshotMetricsNative", .callback = js_snapshotMetricsNative, .length = 0 },
    .{ .name = "clearMetricsNative", .callback = js_clearMetricsNative, .length = 0 },
    .{ .name = "startTraceNative", .callback = js_startTraceNative, .length = 1 },
    .{ .name = "startRootTraceNative", .callback = js_startRootTraceNative, .length = 1 },
    .{ .name = "enterTraceNative", .callback = js_enterTraceNative, .length = 1 },
    .{ .name = "exitTraceNative", .callback = js_exitTraceNative, .length = 1 },
    .{ .name = "endTraceNative", .callback = js_endTraceNative, .length = 2 },
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
    &functions[7],
    &functions[8],
    &functions[9],
    &functions[10],
    &functions[11],
};

pub fn load(ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque {
    return @ptrCast(js_abi.createFunctionModule(allocator(), @ptrCast(ctx), module_name, &function_ptrs));
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

const RuntimeMemoryMetric = struct {
    name: []const u8,
    unit: []const u8,
    read: *const fn (js_abi.MemoryUsage) usize,
};

const runtime_memory_metrics = [_]RuntimeMemoryMetric{
    .{ .name = "malloc_size", .unit = "bytes", .read = memoryMallocSize },
    .{ .name = "malloc_limit", .unit = "bytes", .read = memoryMallocLimit },
    .{ .name = "qjs_used_size", .unit = "bytes", .read = memoryUsedSize },
    .{ .name = "malloc_count", .unit = "count", .read = memoryMallocCount },
    .{ .name = "memory_used_count", .unit = "count", .read = memoryUsedCount },
    .{ .name = "atom_count", .unit = "count", .read = memoryAtomCount },
    .{ .name = "atom_size", .unit = "bytes", .read = memoryAtomSize },
    .{ .name = "str_count", .unit = "count", .read = memoryStrCount },
    .{ .name = "str_size", .unit = "bytes", .read = memoryStrSize },
    .{ .name = "obj_count", .unit = "count", .read = memoryObjCount },
    .{ .name = "obj_size", .unit = "bytes", .read = memoryObjSize },
    .{ .name = "prop_count", .unit = "count", .read = memoryPropCount },
    .{ .name = "prop_size", .unit = "bytes", .read = memoryPropSize },
    .{ .name = "shape_count", .unit = "count", .read = memoryShapeCount },
    .{ .name = "shape_size", .unit = "bytes", .read = memoryShapeSize },
    .{ .name = "js_func_count", .unit = "count", .read = memoryJsFuncCount },
    .{ .name = "js_func_size", .unit = "bytes", .read = memoryJsFuncSize },
    .{ .name = "js_func_code_size", .unit = "bytes", .read = memoryJsFuncCodeSize },
    .{ .name = "array_count", .unit = "count", .read = memoryArrayCount },
    .{ .name = "fast_array_count", .unit = "count", .read = memoryFastArrayCount },
    .{ .name = "fast_array_elements", .unit = "count", .read = memoryFastArrayElements },
    .{ .name = "binary_object_count", .unit = "count", .read = memoryBinaryObjectCount },
    .{ .name = "binary_object_size", .unit = "bytes", .read = memoryBinaryObjectSize },
};

const RuntimeAllocatorMetric = struct {
    name: []const u8,
    unit: []const u8,
    read: *const fn (runtime_allocator.Stats) f64,
};

const runtime_allocator_metrics = [_]RuntimeAllocatorMetric{
    .{ .name = "runtime_active_size", .unit = "bytes", .read = allocatorActiveSize },
    .{ .name = "runtime_peak_size", .unit = "bytes", .read = allocatorPeakSize },
    .{ .name = "runtime_allocated_size", .unit = "bytes", .read = allocatorAllocatedSize },
    .{ .name = "runtime_freed_size", .unit = "bytes", .read = allocatorFreedSize },
    .{ .name = "runtime_allocation_count", .unit = "count", .read = allocatorAllocationCount },
    .{ .name = "runtime_free_count", .unit = "count", .read = allocatorFreeCount },
};

const process_memory_metrics = [_]struct {
    name: []const u8,
    read: *const fn (process_memory.Snapshot) u64,
}{
    .{ .name = "resident_bytes", .read = processResidentBytes },
    .{ .name = "physical_footprint_bytes", .read = processPhysicalFootprintBytes },
};

fn processResidentBytes(snapshot: process_memory.Snapshot) u64 {
    return snapshot.resident_bytes;
}

fn processPhysicalFootprintBytes(snapshot: process_memory.Snapshot) u64 {
    return snapshot.physical_footprint_bytes;
}

fn updatePeak(target: *std.atomic.Value(u64), value: u64) void {
    var current = target.load(.monotonic);
    while (value > current) {
        current = target.cmpxchgWeak(current, value, .monotonic, .monotonic) orelse return;
    }
}

fn memoryMallocSize(usage: js_abi.MemoryUsage) usize {
    return usage.malloc_size;
}

fn memoryMallocLimit(usage: js_abi.MemoryUsage) usize {
    return usage.malloc_limit;
}

fn memoryUsedSize(usage: js_abi.MemoryUsage) usize {
    return usage.memory_used_size;
}

fn memoryMallocCount(usage: js_abi.MemoryUsage) usize {
    return usage.malloc_count;
}

fn memoryUsedCount(usage: js_abi.MemoryUsage) usize {
    return usage.memory_used_count;
}

fn memoryAtomCount(usage: js_abi.MemoryUsage) usize {
    return usage.atom_count;
}

fn memoryAtomSize(usage: js_abi.MemoryUsage) usize {
    return usage.atom_size;
}

fn memoryStrCount(usage: js_abi.MemoryUsage) usize {
    return usage.str_count;
}

fn memoryStrSize(usage: js_abi.MemoryUsage) usize {
    return usage.str_size;
}

fn memoryObjCount(usage: js_abi.MemoryUsage) usize {
    return usage.obj_count;
}

fn memoryObjSize(usage: js_abi.MemoryUsage) usize {
    return usage.obj_size;
}

fn memoryPropCount(usage: js_abi.MemoryUsage) usize {
    return usage.prop_count;
}

fn memoryPropSize(usage: js_abi.MemoryUsage) usize {
    return usage.prop_size;
}

fn memoryShapeCount(usage: js_abi.MemoryUsage) usize {
    return usage.shape_count;
}

fn memoryShapeSize(usage: js_abi.MemoryUsage) usize {
    return usage.shape_size;
}

fn memoryJsFuncCount(usage: js_abi.MemoryUsage) usize {
    return usage.js_func_count;
}

fn memoryJsFuncSize(usage: js_abi.MemoryUsage) usize {
    return usage.js_func_size;
}

fn memoryJsFuncCodeSize(usage: js_abi.MemoryUsage) usize {
    return usage.js_func_code_size;
}

fn memoryArrayCount(usage: js_abi.MemoryUsage) usize {
    return usage.array_count;
}

fn memoryFastArrayCount(usage: js_abi.MemoryUsage) usize {
    return usage.fast_array_count;
}

fn memoryFastArrayElements(usage: js_abi.MemoryUsage) usize {
    return usage.fast_array_elements;
}

fn memoryBinaryObjectCount(usage: js_abi.MemoryUsage) usize {
    return usage.binary_object_count;
}

fn memoryBinaryObjectSize(usage: js_abi.MemoryUsage) usize {
    return usage.binary_object_size;
}

fn allocatorActiveSize(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.active_size);
}

fn allocatorPeakSize(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.peak_size);
}

fn allocatorAllocatedSize(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.allocated_size);
}

fn allocatorFreedSize(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.freed_size);
}

fn allocatorAllocationCount(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.allocation_count);
}

fn allocatorFreeCount(stats: runtime_allocator.Stats) f64 {
    return @floatFromInt(stats.free_count);
}

fn refreshRuntimeMemoryMetrics(ctx: *js_abi.Context) !void {
    const js_ctx = js_abi.borrowContext(ctx) orelse return error.JavaScriptError;
    const usage = js_abi.jsComputeMemoryUsage(js_ctx);
    for (runtime_memory_metrics) |metric| {
        const id = try metrics.register(.{
            .scope = "runtime.memory",
            .name = metric.name,
            .kind = .gauge,
            .unit = metric.unit,
        });
        try metrics.set(id, @floatFromInt(metric.read(usage)));
    }
    const allocator_stats = runtime_allocator.stats();
    for (runtime_allocator_metrics) |metric| {
        const id = try metrics.register(.{
            .scope = "runtime.memory",
            .name = metric.name,
            .kind = .gauge,
            .unit = metric.unit,
        });
        try metrics.set(id, metric.read(allocator_stats));
    }
    const process_snapshot = process_memory.snapshot();
    updatePeak(&peak_resident_bytes, process_snapshot.resident_bytes);
    updatePeak(&peak_physical_footprint_bytes, process_snapshot.physical_footprint_bytes);
    for (process_memory_metrics) |metric| {
        const id = try metrics.register(.{
            .scope = "runtime.memory",
            .name = metric.name,
            .kind = .gauge,
            .unit = "bytes",
        });
        try metrics.set(id, @floatFromInt(metric.read(process_snapshot)));
    }
    const process_peak_metrics = [_]struct {
        name: []const u8,
        value: u64,
    }{
        .{ .name = "peak_resident_bytes", .value = peak_resident_bytes.load(.monotonic) },
        .{ .name = "peak_physical_footprint_bytes", .value = peak_physical_footprint_bytes.load(.monotonic) },
    };
    for (process_peak_metrics) |metric| {
        const id = try metrics.register(.{
            .scope = "runtime.memory",
            .name = metric.name,
            .kind = .gauge,
            .unit = "bytes",
        });
        try metrics.set(id, @floatFromInt(metric.value));
    }
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
    refreshRuntimeMemoryMetrics(ctx) catch return throwInternal(ctx, "failed to refresh runtime memory metrics");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "metric id must be a non-negative integer");
    const current = metrics.value(id) catch return throwInternal(ctx, "failed to read metric");
    return ctx.api.float64_value(ctx, current);
}

fn setStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: []const u8) !void {
    const value_z = try allocator().dupeZ(u8, value);
    defer allocator().free(value_z);
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
    refreshRuntimeMemoryMetrics(ctx) catch return throwInternal(ctx, "failed to refresh runtime memory metrics");
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

fn js_startTraceNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "startTrace requires a name");
    const name = stringFromValue(ctx, argv[0]) orelse return throwType(ctx, "trace name must be a string");
    const id = store.startSpan(name) catch return throwInternal(ctx, "failed to start trace span");
    return ctx.api.int32_value(ctx, @intCast(id));
}

fn js_startRootTraceNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "startRootTrace requires a name");
    const name = stringFromValue(ctx, argv[0]) orelse return throwType(ctx, "trace name must be a string");
    const id = store.startRootSpan(name) catch return throwInternal(ctx, "failed to start root trace span");
    return ctx.api.int32_value(ctx, @intCast(id));
}

fn js_enterTraceNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "enterTrace requires a span id");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "trace span id must be a non-negative integer");
    const scope_id = store.enterSpan(id) catch return throwInternal(ctx, "failed to enter trace span");
    return ctx.api.int32_value(ctx, @intCast(scope_id));
}

fn js_exitTraceNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "exitTrace requires a scope id");
    const scope_id = readId(ctx, argv[0]) catch return throwType(ctx, "trace scope id must be a non-negative integer");
    store.exitSpan(scope_id) catch return throwInternal(ctx, "failed to exit trace span");
    return ctx.api.undefined(ctx);
}

fn js_endTraceNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "endTrace requires a span id");
    const id = readId(ctx, argv[0]) catch return throwType(ctx, "trace span id must be a non-negative integer");
    var status = trace.Status.ok;
    if (argc >= 2) {
        const status_name = stringFromValue(ctx, argv[1]) orelse return throwType(ctx, "trace status must be a string");
        status = if (std.mem.eql(u8, status_name, "err")) .err else if (std.mem.eql(u8, status_name, "unset")) .unset else .ok;
    }
    store.endSpan(id, status) catch return throwInternal(ctx, "failed to end trace span");
    return ctx.api.undefined(ctx);
}

test "telemetry native module can be created" {
    runtime_allocator.init(std.heap.page_allocator);

    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
