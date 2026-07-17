const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");
const console = @import("../../global/console.zig");
const registry = @import("registry.zig");

pub const specifier: [:0]const u8 = "std:test/native";
var current_test_file_path: []const u8 = "";
var current_executable_path: []const u8 = "";
var capture_stdout = std.ArrayList(u8).empty;
var capture_stderr = std.ArrayList(u8).empty;
var capture_active = false;

const functions = [_]js_abi.Function{
    .{ .name = "pushSuite", .callback = js_pushSuite, .length = 1 },
    .{ .name = "popSuite", .callback = js_popSuite, .length = 0 },
    .{ .name = "registerTest", .callback = js_registerTest, .length = 3 },
    .{ .name = "registerHook", .callback = js_registerHook, .length = 2 },
    .{ .name = "getCurrentTestFilePath", .callback = js_getCurrentTestFilePath, .length = 0 },
    .{ .name = "getCurrentExecutablePath", .callback = js_getCurrentExecutablePath, .length = 0 },
    .{ .name = "beginCapture", .callback = js_beginCapture, .length = 1 },
    .{ .name = "endCapture", .callback = js_endCapture, .length = 0 },
    .{ .name = "getRegisteredCounts", .callback = js_getRegisteredCounts, .length = 0 },
    .{ .name = null, .callback = js_popSuite },
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
};

pub fn setCurrentTestFilePath(path: []const u8) void {
    current_test_file_path = path;
}

pub fn setCurrentExecutablePath(path: []const u8) void {
    current_executable_path = path;
}

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &function_ptrs);
}

fn stringArg(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value, index: usize) ?[]const u8 {
    if (argc <= index) return null;
    return std.mem.span(ctx.api.to_string(ctx, argv[index]) orelse return null);
}

fn throwType(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_type_error(ctx, message);
}

fn throwInternal(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_error(ctx, message);
}

fn js_pushSuite(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 1) return throwType(ctx, "describe requires a suite name");
    const name = stringArg(ctx, argc, argv, 0) orelse return throwInternal(ctx, "failed to read suite name");
    registry.pushSuite(name) catch return throwInternal(ctx, "failed to register suite");
    return ctx.api.undefined(ctx);
}

fn js_popSuite(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    registry.popSuite() catch return throwInternal(ctx, "unbalanced describe() nesting");
    return ctx.api.undefined(ctx);
}

fn js_registerTest(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 3 or ctx.api.is_function(ctx, argv[1]) == 0) {
        return throwType(ctx, "test(name, fn, mode) requires a callback");
    }
    const qjs_ctx = js_abi.borrowContext(ctx);
    const callback = js_abi.borrowValue(ctx, argv[1]) orelse return throwInternal(ctx, "failed to read test callback");
    const name = stringArg(ctx, argc, argv, 0) orelse return throwInternal(ctx, "failed to read test name");
    const mode_text = stringArg(ctx, argc, argv, 2) orelse return throwInternal(ctx, "failed to read test mode");
    const mode = std.meta.stringToEnum(registry.TestMode, mode_text) orelse return throwType(ctx, "unknown test mode");
    registry.registerTest(qjs_ctx, name, callback, mode) catch return throwInternal(ctx, "failed to register test");
    return ctx.api.undefined(ctx);
}

fn js_registerHook(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc < 2 or ctx.api.is_function(ctx, argv[1]) == 0) {
        return throwType(ctx, "hook registration requires a name and callback");
    }
    const qjs_ctx = js_abi.borrowContext(ctx);
    const callback = js_abi.borrowValue(ctx, argv[1]) orelse return throwInternal(ctx, "failed to read hook callback");
    const kind_text = stringArg(ctx, argc, argv, 0) orelse return throwInternal(ctx, "failed to read hook kind");
    const kind = std.meta.stringToEnum(registry.HookKind, kind_text) orelse return throwType(ctx, "unknown hook kind");
    registry.registerHook(qjs_ctx, kind, callback) catch return throwInternal(ctx, "failed to register hook");
    return ctx.api.undefined(ctx);
}

fn stringValue(ctx: *js_abi.Context, value: []const u8) js_abi.Value {
    const value_z = std.heap.page_allocator.dupeZ(u8, value) catch return throwInternal(ctx, "out of memory");
    defer std.heap.page_allocator.free(value_z);
    return ctx.api.string_value(ctx, value_z.ptr);
}

fn js_getCurrentTestFilePath(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    return stringValue(ctx, current_test_file_path);
}

fn js_getCurrentExecutablePath(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    return stringValue(ctx, current_executable_path);
}

fn js_beginCapture(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (capture_active) return throwInternal(ctx, "captureOutput does not support nested captures");
    const target_text = if (argc >= 1)
        stringArg(ctx, argc, argv, 0) orelse return throwInternal(ctx, "failed to read capture target")
    else
        "stdout";
    const target = std.meta.stringToEnum(console.CaptureTarget, target_text) orelse {
        return throwType(ctx, "captureOutput target must be 'stdout', 'stderr', or 'both'");
    };
    capture_stdout.clearRetainingCapacity();
    capture_stderr.clearRetainingCapacity();
    console.capture_state = .{
        .target = target,
        .stdout = if (target == .stdout or target == .both) &capture_stdout else null,
        .stderr = if (target == .stderr or target == .both) &capture_stderr else null,
    };
    capture_active = true;
    return ctx.api.undefined(ctx);
}

fn setStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: []const u8) !void {
    const value_z = try std.heap.page_allocator.dupeZ(u8, value);
    defer std.heap.page_allocator.free(value_z);
    const value_handle = ctx.api.string_value(ctx, value_z.ptr);
    if (ctx.api.set_property(ctx, object, key, value_handle) < 0) return error.JavaScriptError;
}

fn js_endCapture(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (!capture_active) return throwInternal(ctx, "captureOutput end called without an active capture");
    capture_active = false;
    console.capture_state = null;
    const obj = ctx.api.object_value(ctx);
    setStringProp(ctx, obj, "stdout", capture_stdout.items) catch return throwInternal(ctx, "failed to create capture result");
    setStringProp(ctx, obj, "stderr", capture_stderr.items) catch return throwInternal(ctx, "failed to create capture result");
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(std.heap.page_allocator);
    combined.appendSlice(std.heap.page_allocator, capture_stdout.items) catch {};
    combined.appendSlice(std.heap.page_allocator, capture_stderr.items) catch {};
    setStringProp(ctx, obj, "combined", combined.items) catch return throwInternal(ctx, "failed to create capture result");
    return obj;
}

fn setIntProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: usize) !void {
    if (ctx.api.set_property(ctx, object, key, ctx.api.int32_value(ctx, @intCast(value))) < 0) return error.JavaScriptError;
}

fn js_getRegisteredCounts(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const obj = ctx.api.object_value(ctx);
    setIntProp(ctx, obj, "suiteDepth", countSuiteDepth(registry.root(), 0)) catch return throwInternal(ctx, "failed to create test counts");
    setIntProp(ctx, obj, "registeredTests", countTests(registry.root())) catch return throwInternal(ctx, "failed to create test counts");
    setIntProp(ctx, obj, "registeredHooks", countHooks(registry.root())) catch return throwInternal(ctx, "failed to create test counts");
    return obj;
}

fn countSuiteDepth(suite: *registry.Suite, depth: usize) usize {
    var max = depth;
    for (suite.children.items) |child| max = @max(max, countSuiteDepth(child, depth + 1));
    return max;
}

fn countTests(suite: *registry.Suite) usize {
    var total = suite.cases.items.len;
    for (suite.children.items) |child| total += countTests(child);
    return total;
}

fn countHooks(suite: *registry.Suite) usize {
    var total = suite.before_all.items.len + suite.after_all.items.len + suite.before_each.items.len + suite.after_each.items.len;
    for (suite.children.items) |child| total += countHooks(child);
    return total;
}

test "test qjs module exports can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
