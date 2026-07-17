const std = @import("std");
const qjs = @import("../../qjs.zig");
const registry = @import("registry.zig");

pub const specifier: [:0]const u8 = "hao:test/native";
var current_test_file_path: []const u8 = "";
var current_executable_path: []const u8 = "";

pub fn setCurrentTestFilePath(path: []const u8) void {
    current_test_file_path = path;
}

pub fn setCurrentExecutablePath(path: []const u8) void {
    current_executable_path = path;
}

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    const module = qjs.c.JS_NewCModule(ctx, module_name, init) orelse return null;
    inline for ([_][:0]const u8{
        "pushSuite",
        "popSuite",
        "registerTest",
        "registerHook",
        "getCurrentTestFilePath",
        "getCurrentExecutablePath",
        "beginCapture",
        "endCapture",
        "getRegisteredCounts",
    }) |name| {
        _ = qjs.c.JS_AddModuleExport(ctx, module, name.ptr);
    }
    return module;
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    if (setExportedFunction(ctx, module, "pushSuite", js_pushSuite, 1) < 0) return -1;
    if (setExportedFunction(ctx, module, "popSuite", js_popSuite, 0) < 0) return -1;
    if (setExportedFunction(ctx, module, "registerTest", js_registerTest, 3) < 0) return -1;
    if (setExportedFunction(ctx, module, "registerHook", js_registerHook, 2) < 0) return -1;
    if (setExportedFunction(ctx, module, "getCurrentTestFilePath", js_getCurrentTestFilePath, 0) < 0) return -1;
    if (setExportedFunction(ctx, module, "getCurrentExecutablePath", js_getCurrentExecutablePath, 0) < 0) return -1;
    if (setExportedFunction(ctx, module, "beginCapture", js_beginCapture, 1) < 0) return -1;
    if (setExportedFunction(ctx, module, "endCapture", js_endCapture, 0) < 0) return -1;
    if (setExportedFunction(ctx, module, "getRegisteredCounts", js_getRegisteredCounts, 0) < 0) return -1;
    return 0;
}

fn setExportedFunction(
    ctx: ?*qjs.c.JSContext,
    module: ?*qjs.c.JSModuleDef,
    name: [:0]const u8,
    func: *const fn (?*qjs.c.JSContext, qjs.c.JSValueConst, c_int, [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue,
    length: c_int,
) c_int {
    const value = qjs.c.JS_NewCFunction(ctx, func, name.ptr, length);
    if (qjs.isException(value)) return -1;
    return qjs.c.JS_SetModuleExport(ctx, module, name.ptr, value);
}

fn allocString(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    return qjs.valueToStringAlloc(ctx, value, allocator);
}

fn throwType(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowTypeError(ctx, message.ptr);
}

fn throwInternal(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowInternalError(ctx, message.ptr);
}

fn js_pushSuite(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 1) return throwType(ctx, "describe requires a suite name");
    const name = allocString(ctx, argv[0], std.heap.page_allocator) catch return throwInternal(ctx, "failed to read suite name");
    defer std.heap.page_allocator.free(name);
    registry.pushSuite(name) catch return throwInternal(ctx, "failed to register suite");
    return qjs.undefinedValue(ctx);
}

fn js_popSuite(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    registry.popSuite() catch return throwInternal(ctx, "unbalanced describe() nesting");
    return qjs.undefinedValue(ctx);
}

fn js_registerTest(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 3 or !qjs.isFunction(ctx, argv[1])) {
        return throwType(ctx, "test(name, fn, mode) requires a callback");
    }
    const name = allocString(ctx, argv[0], std.heap.page_allocator) catch return throwInternal(ctx, "failed to read test name");
    defer std.heap.page_allocator.free(name);
    const mode_text = allocString(ctx, argv[2], std.heap.page_allocator) catch return throwInternal(ctx, "failed to read test mode");
    defer std.heap.page_allocator.free(mode_text);
    const mode = std.meta.stringToEnum(registry.TestMode, mode_text) orelse return throwType(ctx, "unknown test mode");
    registry.registerTest(ctx, name, argv[1], mode) catch return throwInternal(ctx, "failed to register test");
    return qjs.undefinedValue(ctx);
}

fn js_registerHook(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 2 or !qjs.isFunction(ctx, argv[1])) {
        return throwType(ctx, "hook registration requires a name and callback");
    }
    const kind_text = allocString(ctx, argv[0], std.heap.page_allocator) catch return throwInternal(ctx, "failed to read hook kind");
    defer std.heap.page_allocator.free(kind_text);
    const kind = std.meta.stringToEnum(registry.HookKind, kind_text) orelse return throwType(ctx, "unknown hook kind");
    registry.registerHook(ctx, kind, argv[1]) catch return throwInternal(ctx, "failed to register hook");
    return qjs.undefinedValue(ctx);
}

fn js_getCurrentTestFilePath(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return qjs.createString(ctx, current_test_file_path);
}

fn js_getCurrentExecutablePath(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return qjs.createString(ctx, current_executable_path);
}

fn js_beginCapture(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    _ = argc;
    _ = argv;
    return throwInternal(ctx, "captureOutput requires console capture support");
}

fn js_endCapture(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return throwInternal(ctx, "captureOutput requires console capture support");
}

fn js_getRegisteredCounts(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj)) return obj;
    qjs.setProperty(ctx, obj, "suiteDepth", qjs.c.JS_NewInt32(ctx, @intCast(countSuiteDepth(registry.root(), 0)))) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "registeredTests", qjs.c.JS_NewInt32(ctx, @intCast(countTests(registry.root())))) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "registeredHooks", qjs.c.JS_NewInt32(ctx, @intCast(countHooks(registry.root())))) catch return qjs.exceptionValue();
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
