const std = @import("std");
const qjs = @import("../qjs.zig");
const runtime_allocator = @import("../runtime_allocator.zig");
const telemetry_metrics = @import("../telemetry/metrics.zig");

pub const abi_version: u32 = 3;
pub const register_symbol_name = "js_register_modules";
pub const Value = usize;

// Source-level Zig addons use the native QuickJS value contract. Binary addons
// continue to use Value/Context below, which keeps their C ABI stable.
pub const JSValue = qjs.c.JSValue;
pub const JSValueConst = qjs.c.JSValueConst;
pub const JSContext = ?*qjs.c.JSContext;
pub const JSCallback = *const fn (JSContext, JSValueConst, c_int, [*c]JSValueConst) callconv(.c) JSValue;
pub const JSGetter = *const fn (JSContext, JSValueConst) callconv(.c) JSValue;

pub const JSFunction = extern struct {
    name: [*c]const u8,
    callback: JSCallback,
    length: c_int = 0,
};

pub const Context = extern struct {
    api: *const ContextApi,
    data: ?*anyopaque,
};

pub const Registry = extern struct {
    api: *const RegistryApi,
    data: ?*anyopaque,
};

pub const Callback = *const fn (*Context, c_int, [*c]const Value) callconv(.c) Value;

pub const Function = extern struct {
    name: [*c]const u8,
    callback: Callback,
    length: c_int = 0,
};

pub const Module = extern struct {
    specifier: [*:0]const u8,
    functions: [*c]const Function,
    function_count: usize,
};

pub const MetricDefinition = extern struct {
    scope: [*c]const u8,
    name: [*c]const u8,
    kind: u32,
    unit: [*c]const u8,
};

pub const RegisterModulesFn = *const fn (*Registry) callconv(.c) c_int;

pub const RegistryApi = extern struct {
    abi_version: u32 = abi_version,
    add_module: *const fn (*Registry, *const Module) callconv(.c) c_int,
};

pub const ContextApi = extern struct {
    abi_version: u32 = abi_version,
    undefined: *const fn (*Context) callconv(.c) Value,
    null_value: *const fn (*Context) callconv(.c) Value,
    bool_value: *const fn (*Context, c_int) callconv(.c) Value,
    int32_value: *const fn (*Context, i32) callconv(.c) Value,
    float64_value: *const fn (*Context, f64) callconv(.c) Value,
    string_value: *const fn (*Context, [*:0]const u8) callconv(.c) Value,
    to_bool: *const fn (*Context, Value, *c_int) callconv(.c) c_int,
    to_int32: *const fn (*Context, Value, *i32) callconv(.c) c_int,
    to_float64: *const fn (*Context, Value, *f64) callconv(.c) c_int,
    to_string: *const fn (*Context, Value) callconv(.c) ?[*:0]const u8,
    throw_type_error: *const fn (*Context, [*:0]const u8) callconv(.c) Value,
    throw_error: *const fn (*Context, [*:0]const u8) callconv(.c) Value,
    object_value: *const fn (*Context) callconv(.c) Value,
    set_property: *const fn (*Context, Value, [*:0]const u8, Value) callconv(.c) c_int,
    get_property: *const fn (*Context, Value, [*:0]const u8) callconv(.c) Value,
    is_undefined: *const fn (*Context, Value) callconv(.c) c_int,
    is_null: *const fn (*Context, Value) callconv(.c) c_int,
    is_object: *const fn (*Context, Value) callconv(.c) c_int,
    is_array: *const fn (*Context, Value) callconv(.c) c_int,
    is_function: *const fn (*Context, Value) callconv(.c) c_int,
    array_length: *const fn (*Context, Value, *u32) callconv(.c) c_int,
    array_get: *const fn (*Context, Value, u32) callconv(.c) Value,
    array_value: *const fn (*Context) callconv(.c) Value,
    array_set: *const fn (*Context, Value, u32, Value) callconv(.c) c_int,
    metric_register: *const fn (*Context, *const MetricDefinition, *u32) callconv(.c) c_int,
    metric_add: *const fn (*Context, u32, f64) callconv(.c) c_int,
    metric_set: *const fn (*Context, u32, f64) callconv(.c) c_int,
    metric_observe: *const fn (*Context, u32, f64) callconv(.c) c_int,
    metric_value: *const fn (*Context, u32, *f64) callconv(.c) c_int,
};

fn alignedSize(size: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, size, alignment);
}

test "native abi structs keep C layout" {
    const ptr_size = @sizeOf(usize);

    try std.testing.expectEqual(@as(usize, ptr_size), @sizeOf(Value));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Context, "api"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(Context, "data"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @sizeOf(Context));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Registry, "api"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(Registry, "data"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @sizeOf(Registry));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Function, "name"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(Function, "callback"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @offsetOf(Function, "length"));
    try std.testing.expectEqual(alignedSize(ptr_size * 2 + @sizeOf(c_int), @alignOf(Function)), @sizeOf(Function));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Module, "specifier"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(Module, "functions"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @offsetOf(Module, "function_count"));
    try std.testing.expectEqual(@as(usize, ptr_size * 3), @sizeOf(Module));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MetricDefinition, "scope"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(MetricDefinition, "name"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @offsetOf(MetricDefinition, "kind"));
    try std.testing.expectEqual(alignedSize(ptr_size * 3 + @sizeOf(u32), @alignOf(MetricDefinition)), @sizeOf(MetricDefinition));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(RegistryApi, "abi_version"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(RegistryApi, "add_module"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @sizeOf(RegistryApi));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ContextApi, "abi_version"));
    try std.testing.expectEqual(@as(usize, ptr_size), @offsetOf(ContextApi, "undefined"));
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @offsetOf(ContextApi, "null_value"));
    try std.testing.expectEqual(@as(usize, ptr_size * 24), @offsetOf(ContextApi, "array_set"));
    try std.testing.expectEqual(@as(usize, ptr_size * 25), @offsetOf(ContextApi, "metric_register"));
    try std.testing.expectEqual(@as(usize, ptr_size * 29), @offsetOf(ContextApi, "metric_value"));
    try std.testing.expectEqual(@as(usize, ptr_size * 30), @sizeOf(ContextApi));
}

const CallFrame = struct {
    ctx: ?*qjs.c.JSContext,
    argv: [*c]qjs.c.JSValueConst,
    argc: c_int,
    values: std.ArrayList(qjs.c.JSValue),
    strings: std.ArrayList([:0]u8),

    fn init(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst) CallFrame {
        return .{
            .ctx = ctx,
            .argc = argc,
            .argv = argv,
            .values = .empty,
            .strings = .empty,
        };
    }

    fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        for (self.values.items) |value| qjs.freeValue(self.ctx, value);
        self.values.deinit(allocator);
        for (self.strings.items) |value| allocator.free(value);
        self.strings.deinit(allocator);
    }

    fn toJsValueConst(self: *CallFrame, value: Value) ?qjs.c.JSValueConst {
        if (value == 0) return qjs.undefinedValue(self.ctx);
        const argc_usize: usize = @intCast(@max(self.argc, 0));
        if (value <= argc_usize) return self.argv[value - 1];
        const owned_idx = value - argc_usize - 1;
        if (owned_idx >= self.values.items.len) return null;
        return self.values.items[owned_idx];
    }

    fn pushValue(self: *CallFrame, allocator: std.mem.Allocator, value: qjs.c.JSValue) Value {
        self.values.append(allocator, value) catch {
            qjs.freeValue(self.ctx, value);
            return pushException(self, "out of memory");
        };
        const argc_usize: usize = @intCast(@max(self.argc, 0));
        return argc_usize + self.values.items.len;
    }

    fn pushException(self: *CallFrame, message: []const u8) Value {
        _ = qjs.c.JS_ThrowInternalError(self.ctx, "%.*s", @as(c_int, @intCast(message.len)), message.ptr);
        return pushRawException(self);
    }

    fn pushRawException(self: *CallFrame) Value {
        const value = qjs.exceptionValue();
        self.values.append(runtime_allocator.allocator(), value) catch {};
        const argc_usize: usize = @intCast(@max(self.argc, 0));
        return argc_usize + self.values.items.len;
    }
};

const ContextData = struct {
    allocator: std.mem.Allocator,
    frame: *CallFrame,
};

pub const HostObjectFinalizer = *const fn (u32, u64) callconv(.c) void;

const HostObjectData = struct {
    type_id: u32,
    handle: u64,
    finalizer: HostObjectFinalizer,
};

var host_object_class_id: qjs.c.JSClassID = 0;
var host_object_class_ready = false;
var host_object_class_runtime: ?*qjs.c.JSRuntime = null;

fn hostObjectFinalize(_: ?*qjs.c.JSRuntime, value: qjs.c.JSValue) callconv(.c) void {
    const raw = qjs.c.JS_GetOpaque(value, qjs.c.JS_GetClassID(value)) orelse return;
    const data: *HostObjectData = @ptrCast(@alignCast(raw));
    data.finalizer(data.type_id, data.handle);
    runtime_allocator.allocator().destroy(data);
}

fn ensureHostObjectClass(ctx: ?*qjs.c.JSContext) !qjs.c.JSClassID {
    const runtime = qjs.c.JS_GetRuntime(ctx);
    if (host_object_class_ready and host_object_class_runtime == runtime and qjs.c.JS_IsRegisteredClass(runtime, host_object_class_id)) return host_object_class_id;
    _ = qjs.c.JS_NewClassID(runtime, &host_object_class_id);
    const class_def = std.mem.zeroInit(qjs.c.JSClassDef, .{
        .class_name = "HostObject",
        .finalizer = hostObjectFinalize,
    });
    if (qjs.c.JS_NewClass(runtime, host_object_class_id, &class_def) < 0) return error.HostObjectClassRegistrationFailed;
    host_object_class_ready = true;
    host_object_class_runtime = runtime;
    return host_object_class_id;
}

pub fn jsRuntime(ctx: JSContext) ?*anyopaque {
    return @ptrCast(qjs.c.JS_GetRuntime(ctx));
}

pub fn jsHostObjectClassIsValid(ctx: JSContext, class_id: u32) bool {
    return qjs.c.JS_IsRegisteredClass(qjs.c.JS_GetRuntime(ctx), class_id);
}

// Addons can use a separate QuickJS class when an object has its own method
// surface. The class remains owned by Hao; addons only retain its numeric id.
pub fn jsCreateHostObjectClass(ctx: JSContext, name: [*:0]const u8) u32 {
    const runtime = qjs.c.JS_GetRuntime(ctx);
    var class_id: qjs.c.JSClassID = 0;
    _ = qjs.c.JS_NewClassID(runtime, &class_id);
    const class_def = std.mem.zeroInit(qjs.c.JSClassDef, .{
        .class_name = name,
        .finalizer = hostObjectFinalize,
    });
    if (qjs.c.JS_NewClass(runtime, class_id, &class_def) < 0) return 0;
    return class_id;
}

pub fn createHostObject(context: *Context, type_id: u32, handle: u64, finalizer: HostObjectFinalizer) Value {
    const data = contextData(context);
    const class_id = ensureHostObjectClass(data.frame.ctx) catch return data.frame.pushException("host object class unavailable");
    const object = qjs.c.JS_NewObjectClass(data.frame.ctx, class_id);
    if (qjs.isException(object)) return data.frame.pushRawException();
    const payload = data.allocator.create(HostObjectData) catch {
        qjs.freeValue(data.frame.ctx, object);
        return data.frame.pushException("out of memory");
    };
    payload.* = .{ .type_id = type_id, .handle = handle, .finalizer = finalizer };
    _ = qjs.c.JS_SetOpaque(object, payload);
    return pushJs(context, object);
}

pub fn hostObjectHandle(context: *Context, value: Value, expected_type_id: u32) ?u64 {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return null;
    const class_id = ensureHostObjectClass(data.frame.ctx) catch return null;
    const raw = qjs.c.JS_GetOpaque2(data.frame.ctx, js_value, class_id) orelse return null;
    const payload: *HostObjectData = @ptrCast(@alignCast(raw));
    if (payload.type_id != expected_type_id) {
        _ = qjs.c.JS_ThrowTypeError(data.frame.ctx, "wrong host object type");
        return null;
    }
    return payload.handle;
}

pub fn createJSHostObject(ctx: JSContext, type_id: u32, handle: u64, finalizer: HostObjectFinalizer) JSValue {
    const class_id = ensureHostObjectClass(ctx) catch return qjs.exceptionValue();
    return createJSHostObjectWithClass(ctx, class_id, type_id, handle, finalizer);
}

pub fn createJSHostObjectWithClass(ctx: JSContext, class_id: u32, type_id: u32, handle: u64, finalizer: HostObjectFinalizer) JSValue {
    const object = qjs.c.JS_NewObjectClass(ctx, class_id);
    if (qjs.isException(object)) return object;
    const payload = runtime_allocator.allocator().create(HostObjectData) catch {
        qjs.freeValue(ctx, object);
        return qjs.exceptionValue();
    };
    payload.* = .{ .type_id = type_id, .handle = handle, .finalizer = finalizer };
    _ = qjs.c.JS_SetOpaque(object, payload);
    return object;
}

pub fn jsHostObjectHandle(ctx: JSContext, value: JSValueConst, expected_type_id: u32) ?u64 {
    const class_id = ensureHostObjectClass(ctx) catch return null;
    return jsHostObjectHandleWithClass(ctx, value, class_id, expected_type_id);
}

pub fn jsHostObjectHandleWithClass(ctx: JSContext, value: JSValueConst, class_id: u32, expected_type_id: u32) ?u64 {
    const raw = qjs.c.JS_GetOpaque2(ctx, value, class_id) orelse return null;
    const payload: *HostObjectData = @ptrCast(@alignCast(raw));
    if (payload.type_id != expected_type_id) {
        _ = qjs.c.JS_ThrowTypeError(ctx, "wrong host object type");
        return null;
    }
    return payload.handle;
}

pub fn jsSetProperty(ctx: JSContext, object: JSValueConst, key: [*:0]const u8, value: JSValue) c_int {
    return qjs.c.JS_DefinePropertyValueStr(
        ctx,
        object,
        key,
        value,
        qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE,
    );
}

pub fn jsSetHiddenProperty(ctx: JSContext, object: JSValueConst, key: [*:0]const u8, value: JSValue) c_int {
    return qjs.c.JS_DefinePropertyValueStr(
        ctx,
        object,
        key,
        value,
        qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_CONFIGURABLE,
    );
}

pub fn jsSetArrayElement(ctx: JSContext, array: JSValueConst, index: u32, value: JSValue) c_int {
    return qjs.c.JS_DefinePropertyValueUint32(
        ctx,
        array,
        index,
        value,
        qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE,
    );
}

pub fn jsSetFunction(ctx: JSContext, object: JSValueConst, name: [*:0]const u8, callback: JSCallback, length: c_int) c_int {
    const function = qjs.c.JS_NewCFunction(ctx, callback, name, length);
    if (qjs.isException(function)) return -1;
    return jsSetProperty(ctx, object, name, function);
}

pub fn jsSetGetter(ctx: JSContext, object: JSValueConst, name: [*:0]const u8, callback: JSGetter) c_int {
    const atom = qjs.c.JS_NewAtom(ctx, name);
    defer qjs.c.JS_FreeAtom(ctx, atom);
    const getter = qjs.c.JS_NewCFunction2(ctx, @ptrCast(@constCast(callback)), name, 0, qjs.c.JS_CFUNC_getter, 0);
    if (qjs.isException(getter)) return -1;
    return qjs.c.JS_DefinePropertyGetSet(
        ctx,
        object,
        atom,
        getter,
        qjs.undefinedValue(ctx),
        qjs.c.JS_PROP_HAS_GET | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE | qjs.c.JS_PROP_HAS_CONFIGURABLE | qjs.c.JS_PROP_CONFIGURABLE,
    );
}

// Source-level addons use these helpers instead of depending on QuickJS directly.
pub fn jsExceptionValue() JSValue {
    return qjs.exceptionValue();
}

pub fn jsIsException(value: JSValueConst) bool {
    return qjs.isException(value);
}

pub fn jsFreeValue(ctx: JSContext, value: JSValue) void {
    qjs.freeValue(ctx, value);
}

pub fn jsDupValue(ctx: JSContext, value: JSValueConst) JSValue {
    return qjs.dupValue(ctx, value);
}

pub fn jsThrowError(ctx: JSContext, message: [*:0]const u8) JSValue {
    _ = qjs.c.JS_ThrowInternalError(ctx, "%s", message);
    return qjs.exceptionValue();
}

pub fn jsThrowTypeError(ctx: JSContext, message: [*:0]const u8) JSValue {
    _ = qjs.c.JS_ThrowTypeError(ctx, "%s", message);
    return qjs.exceptionValue();
}

pub fn jsNewArray(ctx: JSContext) JSValue {
    return qjs.c.JS_NewArray(ctx);
}

pub fn jsInt32(ctx: JSContext, value: i32) JSValue {
    return qjs.c.JS_NewInt32(ctx, value);
}

pub fn jsString(ctx: JSContext, value: []const u8) JSValue {
    return qjs.createString(ctx, value);
}

pub fn jsStringAlloc(ctx: JSContext, value: JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    return qjs.valueToStringAlloc(ctx, value, allocator);
}

pub fn jsIsNumber(value: JSValueConst) bool {
    return qjs.isNumber(value);
}

pub fn jsGetProperty(ctx: JSContext, object: JSValueConst, key: [:0]const u8) JSValue {
    return qjs.getProperty(ctx, object, key);
}

pub fn jsGetArrayElement(ctx: JSContext, array: JSValueConst, index: u32) JSValue {
    return qjs.c.JS_GetPropertyUint32(ctx, array, index);
}

pub fn jsNewObject(ctx: JSContext) JSValue {
    return qjs.newObject(ctx);
}

pub fn jsBool(ctx: JSContext, value: bool) JSValue {
    return qjs.c.JS_NewBool(ctx, value);
}

pub fn jsFloat64(ctx: JSContext, value: f64) JSValue {
    return qjs.c.JS_NewFloat64(ctx, value);
}

pub fn jsToBool(ctx: JSContext, out: *bool, value: JSValueConst) c_int {
    var result: c_int = 0;
    const status = qjs.c.JS_ToBool(ctx, value);
    if (status < 0) return -1;
    result = status;
    out.* = result != 0;
    return 0;
}

pub fn jsUndefined(ctx: JSContext) JSValue {
    return qjs.undefinedValue(ctx);
}

pub fn jsCall(ctx: JSContext, function: JSValueConst, this_value: JSValueConst, args: []const JSValueConst) JSValue {
    return qjs.call(ctx, function, this_value, args);
}

pub fn jsNull(ctx: JSContext) JSValue {
    return qjs.nullValue(ctx);
}

pub fn jsIsUndefined(value: JSValueConst) bool {
    return qjs.isUndefined(value);
}

pub fn jsIsNull(value: JSValueConst) bool {
    return qjs.isNull(value);
}

pub fn jsStringEquals(ctx: JSContext, value: JSValueConst, expected: [:0]const u8) bool {
    var length: usize = 0;
    const text = qjs.c.JS_ToCStringLen2(ctx, &length, value, false) orelse return false;
    defer qjs.c.JS_FreeCString(ctx, text);
    return std.mem.eql(u8, text[0..length], expected);
}

pub fn jsIsArray(ctx: JSContext, value: JSValueConst) bool {
    return qjs.isArray(ctx, value);
}

pub fn jsIsString(value: JSValueConst) bool {
    return qjs.isString(value);
}

pub fn jsToInt32(ctx: JSContext, out: *i32, value: JSValueConst) c_int {
    return qjs.c.JS_ToInt32(ctx, out, value);
}

pub fn jsToFloat64(ctx: JSContext, out: *f64, value: JSValueConst) c_int {
    return qjs.c.JS_ToFloat64(ctx, out, value);
}

const JSFunctionTable = struct {
    allocator: std.mem.Allocator,
    functions: []const *const JSFunction,
};

pub fn createJSFunctionModule(
    allocator: std.mem.Allocator,
    ctx: JSContext,
    module_name: [*c]const u8,
    functions: []const *const JSFunction,
) ?*qjs.c.JSModuleDef {
    if (functions.len == 0) return null;
    const table = allocator.create(JSFunctionTable) catch return null;
    const stored_functions = allocator.dupe(*const JSFunction, functions) catch {
        allocator.destroy(table);
        return null;
    };
    table.* = .{ .allocator = allocator, .functions = stored_functions };
    const module = qjs.c.JS_NewCModule(ctx, module_name, initJSFunctionModule) orelse {
        allocator.free(stored_functions);
        allocator.destroy(table);
        return null;
    };
    const table_ptr: i64 = @bitCast(@intFromPtr(table));
    _ = qjs.c.JS_SetModulePrivateValue(ctx, module, qjs.c.JS_NewInt64(ctx, table_ptr));
    _ = qjs.c.JS_AddModuleExport(ctx, module, "default");
    for (functions) |function| _ = qjs.c.JS_AddModuleExport(ctx, module, function.name.?);
    return module;
}

fn initJSFunctionModule(ctx: JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    const private = qjs.c.JS_GetModulePrivateValue(ctx, module);
    var stored_ptr: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &stored_ptr, private) < 0) return -1;
    const table: *const JSFunctionTable = @ptrFromInt(@as(usize, @bitCast(stored_ptr)));
    const allocator = table.allocator;
    const functions = table.functions;
    defer allocator.free(functions);
    allocator.destroy(@constCast(table));

    const exports = qjs.newObject(ctx);
    if (qjs.isException(exports)) return -1;
    defer qjs.freeValue(ctx, exports);
    for (functions) |function| {
        const function_ptr: i64 = @bitCast(@intFromPtr(function));
        var data = [_]qjs.c.JSValue{qjs.c.JS_NewInt64(ctx, function_ptr)};
        const value = qjs.c.JS_NewCFunctionData(ctx, callJSFunction, function.length, 0, 1, &data);
        if (qjs.isException(value)) return -1;
        const name = function.name orelse return -1;
        if (qjs.c.JS_SetModuleExport(ctx, module, name, qjs.dupValue(ctx, value)) < 0) return -1;
        if (qjs.c.JS_DefinePropertyValueStr(ctx, exports, name, value, qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE) < 0) return -1;
    }
    return qjs.c.JS_SetModuleExport(ctx, module, "default", qjs.dupValue(ctx, exports));
}

fn callJSFunction(
    ctx: JSContext,
    this_value: JSValueConst,
    argc: c_int,
    argv: [*c]JSValueConst,
    _: c_int,
    func_data: [*c]JSValue,
) callconv(.c) JSValue {
    var ptr_value: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &ptr_value, func_data[0]) < 0) return qjs.exceptionValue();
    const function: *const JSFunction = @ptrFromInt(@as(usize, @bitCast(ptr_value)));
    return function.callback(ctx, this_value, argc, argv);
}

pub const FunctionModule = struct {
    specifier: [:0]const u8,
    functions: []const *const Function,
};

const FunctionTable = struct {
    allocator: std.mem.Allocator,
    functions: []const *const Function,
    count: usize,
};

pub const ModuleCollector = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(FunctionModule),

    pub fn init(allocator: std.mem.Allocator) ModuleCollector {
        return .{ .allocator = allocator, .modules = .empty };
    }

    pub fn deinit(self: *ModuleCollector) void {
        for (self.modules.items) |module| {
            self.allocator.free(module.specifier);
            self.allocator.free(module.functions);
        }
        self.modules.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registry(self: *ModuleCollector) Registry {
        return .{
            .api = &registry_api,
            .data = self,
        };
    }

    fn addModule(self: *ModuleCollector, module: *const Module) !void {
        const specifier = try self.allocator.dupeZ(u8, std.mem.span(module.specifier));
        errdefer self.allocator.free(specifier);

        var functions: std.ArrayList(*const Function) = .empty;
        errdefer functions.deinit(self.allocator);
        for (0..module.function_count) |i| {
            const function: *const Function = @ptrCast(&module.functions[i]);
            try functions.append(self.allocator, function);
        }

        try self.modules.append(self.allocator, .{
            .specifier = specifier,
            .functions = try functions.toOwnedSlice(self.allocator),
        });
    }
};

fn registryAddModule(registry: *Registry, module: *const Module) callconv(.c) c_int {
    if (registry.api.abi_version != abi_version) return -1;
    const collector: *ModuleCollector = @ptrCast(@alignCast(registry.data orelse return -1));
    collector.addModule(module) catch return -1;
    return 0;
}

const registry_api = RegistryApi{
    .add_module = registryAddModule,
};

fn contextData(context: *Context) *ContextData {
    std.debug.assert(context.api.abi_version == abi_version);
    return @ptrCast(@alignCast(context.data.?));
}

fn pushJs(context: *Context, value: qjs.c.JSValue) Value {
    const data = contextData(context);
    return data.frame.pushValue(data.allocator, value);
}

pub fn adoptValue(context: *Context, value: qjs.c.JSValue) Value {
    return pushJs(context, value);
}

fn valueToJs(context: *Context, value: Value) ?qjs.c.JSValueConst {
    return contextData(context).frame.toJsValueConst(value);
}

pub fn borrowContext(context: *Context) ?*qjs.c.JSContext {
    return contextData(context).frame.ctx;
}

pub fn borrowValue(context: *Context, value: Value) ?qjs.c.JSValueConst {
    return valueToJs(context, value);
}

fn contextUndefined(context: *Context) callconv(.c) Value {
    return pushJs(context, qjs.undefinedValue(contextData(context).frame.ctx));
}

fn contextNull(context: *Context) callconv(.c) Value {
    return pushJs(context, qjs.nullValue(contextData(context).frame.ctx));
}

fn contextBool(context: *Context, value: c_int) callconv(.c) Value {
    return pushJs(context, qjs.boolValue(contextData(context).frame.ctx, value != 0));
}

fn contextInt32(context: *Context, value: i32) callconv(.c) Value {
    return pushJs(context, qjs.c.JS_NewInt32(contextData(context).frame.ctx, value));
}

fn contextFloat64(context: *Context, value: f64) callconv(.c) Value {
    return pushJs(context, qjs.c.JS_NewFloat64(contextData(context).frame.ctx, value));
}

fn contextString(context: *Context, value: [*:0]const u8) callconv(.c) Value {
    return pushJs(context, qjs.createString(contextData(context).frame.ctx, std.mem.span(value)));
}

fn contextObject(context: *Context) callconv(.c) Value {
    return pushJs(context, qjs.newObject(contextData(context).frame.ctx));
}

fn contextSetProperty(context: *Context, object: Value, key: [*:0]const u8, value: Value) callconv(.c) c_int {
    const data = contextData(context);
    const js_object = valueToJs(context, object) orelse return -1;
    const js_value = valueToJs(context, value) orelse return -1;
    return qjs.c.JS_DefinePropertyValueStr(
        data.frame.ctx,
        js_object,
        key,
        qjs.dupValue(data.frame.ctx, js_value),
        qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE,
    );
}

fn contextGetProperty(context: *Context, object: Value, key: [*:0]const u8) callconv(.c) Value {
    const js_object = valueToJs(context, object) orelse return contextData(context).frame.pushException("invalid object handle");
    return pushJs(context, qjs.getProperty(contextData(context).frame.ctx, js_object, std.mem.span(key)));
}

fn contextIsUndefined(context: *Context, value: Value) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return 0;
    return if (qjs.isUndefined(js_value)) 1 else 0;
}

fn contextIsNull(context: *Context, value: Value) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return 0;
    return if (qjs.isNull(js_value)) 1 else 0;
}

fn contextIsObject(context: *Context, value: Value) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return 0;
    return if (qjs.isObject(js_value)) 1 else 0;
}

fn contextIsArray(context: *Context, value: Value) callconv(.c) c_int {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return 0;
    return if (qjs.isArray(data.frame.ctx, js_value)) 1 else 0;
}

fn contextIsFunction(context: *Context, value: Value) callconv(.c) c_int {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return 0;
    return if (qjs.isFunction(data.frame.ctx, js_value)) 1 else 0;
}

fn contextArrayLength(context: *Context, value: Value, out: *u32) callconv(.c) c_int {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return -1;
    const length_value = qjs.getProperty(data.frame.ctx, js_value, "length");
    defer qjs.freeValue(data.frame.ctx, length_value);
    var length_i32: i32 = 0;
    if (qjs.c.JS_ToInt32(data.frame.ctx, &length_i32, length_value) < 0 or length_i32 < 0) return -1;
    out.* = @intCast(length_i32);
    return 0;
}

fn contextArrayGet(context: *Context, value: Value, index: u32) callconv(.c) Value {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return data.frame.pushException("invalid array handle");
    return pushJs(context, qjs.c.JS_GetPropertyUint32(data.frame.ctx, js_value, index));
}

fn contextArray(context: *Context) callconv(.c) Value {
    return pushJs(context, qjs.c.JS_NewArray(contextData(context).frame.ctx));
}

fn contextArraySet(context: *Context, array: Value, index: u32, value: Value) callconv(.c) c_int {
    const data = contextData(context);
    const js_array = valueToJs(context, array) orelse return -1;
    const js_value = valueToJs(context, value) orelse return -1;
    return qjs.c.JS_DefinePropertyValueUint32(
        data.frame.ctx,
        js_array,
        index,
        qjs.dupValue(data.frame.ctx, js_value),
        qjs.c.JS_PROP_HAS_VALUE | qjs.c.JS_PROP_HAS_ENUMERABLE | qjs.c.JS_PROP_ENUMERABLE,
    );
}

fn metricKindFromAbi(kind: u32) ?telemetry_metrics.Kind {
    return switch (kind) {
        @intFromEnum(telemetry_metrics.Kind.counter) => .counter,
        @intFromEnum(telemetry_metrics.Kind.gauge) => .gauge,
        @intFromEnum(telemetry_metrics.Kind.histogram) => .histogram,
        else => null,
    };
}

fn contextMetricRegister(_: *Context, definition: *const MetricDefinition, out_id: *u32) callconv(.c) c_int {
    const scope_ptr = definition.scope orelse return -1;
    const name_ptr = definition.name orelse return -1;
    const kind = metricKindFromAbi(definition.kind) orelse return -1;
    const unit = if (definition.unit) |unit_ptr| std.mem.span(unit_ptr) else "";
    const id = telemetry_metrics.register(.{
        .scope = std.mem.span(scope_ptr),
        .name = std.mem.span(name_ptr),
        .kind = kind,
        .unit = unit,
    }) catch return -1;
    out_id.* = id;
    return 0;
}

fn contextMetricAdd(_: *Context, id: u32, delta: f64) callconv(.c) c_int {
    telemetry_metrics.add(id, delta) catch return -1;
    return 0;
}

fn contextMetricSet(_: *Context, id: u32, value: f64) callconv(.c) c_int {
    telemetry_metrics.set(id, value) catch return -1;
    return 0;
}

fn contextMetricObserve(_: *Context, id: u32, value: f64) callconv(.c) c_int {
    telemetry_metrics.observe(id, value) catch return -1;
    return 0;
}

fn contextMetricValue(_: *Context, id: u32, out: *f64) callconv(.c) c_int {
    out.* = telemetry_metrics.value(id) catch return -1;
    return 0;
}

fn contextToBool(context: *Context, value: Value, out: *c_int) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return -1;
    out.* = qjs.c.JS_ToBool(contextData(context).frame.ctx, js_value);
    return 0;
}

fn contextToInt32(context: *Context, value: Value, out: *i32) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return -1;
    return qjs.c.JS_ToInt32(contextData(context).frame.ctx, out, js_value);
}

fn contextToFloat64(context: *Context, value: Value, out: *f64) callconv(.c) c_int {
    const js_value = valueToJs(context, value) orelse return -1;
    return qjs.c.JS_ToFloat64(contextData(context).frame.ctx, out, js_value);
}

fn contextToString(context: *Context, value: Value) callconv(.c) ?[*:0]const u8 {
    const data = contextData(context);
    const js_value = valueToJs(context, value) orelse return null;
    const owned = qjs.valueToStringAlloc(data.frame.ctx, js_value, data.allocator) catch return null;
    defer data.allocator.free(owned);
    const owned_z = data.allocator.dupeZ(u8, owned) catch return null;
    data.frame.strings.append(data.allocator, owned_z) catch {
        data.allocator.free(owned_z);
        return null;
    };
    return owned_z.ptr;
}

fn contextThrowTypeError(context: *Context, message: [*:0]const u8) callconv(.c) Value {
    const data = contextData(context);
    _ = qjs.c.JS_ThrowTypeError(data.frame.ctx, "%s", message);
    return data.frame.pushRawException();
}

fn contextThrowError(context: *Context, message: [*:0]const u8) callconv(.c) Value {
    const data = contextData(context);
    _ = qjs.c.JS_ThrowInternalError(data.frame.ctx, "%s", message);
    return data.frame.pushRawException();
}

const context_api = ContextApi{
    .undefined = contextUndefined,
    .null_value = contextNull,
    .bool_value = contextBool,
    .int32_value = contextInt32,
    .float64_value = contextFloat64,
    .string_value = contextString,
    .to_bool = contextToBool,
    .to_int32 = contextToInt32,
    .to_float64 = contextToFloat64,
    .to_string = contextToString,
    .throw_type_error = contextThrowTypeError,
    .throw_error = contextThrowError,
    .object_value = contextObject,
    .set_property = contextSetProperty,
    .get_property = contextGetProperty,
    .is_undefined = contextIsUndefined,
    .is_null = contextIsNull,
    .is_object = contextIsObject,
    .is_array = contextIsArray,
    .is_function = contextIsFunction,
    .array_length = contextArrayLength,
    .array_get = contextArrayGet,
    .array_value = contextArray,
    .array_set = contextArraySet,
    .metric_register = contextMetricRegister,
    .metric_add = contextMetricAdd,
    .metric_set = contextMetricSet,
    .metric_observe = contextMetricObserve,
    .metric_value = contextMetricValue,
};

pub fn createFunctionModule(
    allocator: std.mem.Allocator,
    ctx: ?*qjs.c.JSContext,
    module_name: [*c]const u8,
    functions: []const *const Function,
) ?*qjs.c.JSModuleDef {
    if (functions.len == 0) return null;
    const table = allocator.create(FunctionTable) catch return null;
    const stored_functions = allocator.alloc(*const Function, functions.len) catch {
        allocator.destroy(table);
        return null;
    };
    @memcpy(stored_functions, functions);
    table.* = .{ .allocator = allocator, .functions = stored_functions, .count = functions.len };
    const module = qjs.c.JS_NewCModule(ctx, module_name, initFunctionModule) orelse {
        allocator.free(stored_functions);
        allocator.destroy(table);
        return null;
    };
    const table_ptr: i64 = @bitCast(@intFromPtr(table));
    _ = qjs.c.JS_SetModulePrivateValue(ctx, module, qjs.c.JS_NewInt64(ctx, table_ptr));
    _ = qjs.c.JS_AddModuleExport(ctx, module, "default");
    for (functions) |function| {
        _ = qjs.c.JS_AddModuleExport(ctx, module, function.name.?);
    }
    return module;
}

fn initFunctionModule(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    const private = qjs.c.JS_GetModulePrivateValue(ctx, module);
    var stored_ptr: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &stored_ptr, private) < 0) return -1;
    const table: *const FunctionTable = @ptrFromInt(@as(usize, @bitCast(stored_ptr)));
    const table_allocator = table.allocator;
    const functions = table.functions;
    const function_count = table.count;
    defer table_allocator.free(functions);
    table_allocator.destroy(@constCast(table));
    const exports = qjs.newObject(ctx);
    if (qjs.isException(exports)) return -1;
    defer qjs.freeValue(ctx, exports);

    for (0..function_count) |i| {
        const function = functions[i];
        const function_ptr: i64 = @bitCast(@intFromPtr(function));
        var data = [_]qjs.c.JSValue{qjs.c.JS_NewInt64(ctx, function_ptr)};
        const value = qjs.c.JS_NewCFunctionData(ctx, callNativeFunction, function.length, 0, 1, &data);
        if (qjs.isException(value)) return -1;
        const name = function.name orelse return -1;
        if (qjs.c.JS_SetModuleExport(ctx, module, name, qjs.dupValue(ctx, value)) < 0) return -1;
        qjs.setProperty(ctx, exports, std.mem.span(name), value) catch return -1;
    }

    if (qjs.c.JS_SetModuleExport(ctx, module, "default", qjs.dupValue(ctx, exports)) < 0) return -1;
    return 0;
}

fn callNativeFunction(
    ctx: ?*qjs.c.JSContext,
    _: qjs.c.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.c.JSValueConst,
    _: c_int,
    func_data: [*c]qjs.c.JSValue,
) callconv(.c) qjs.c.JSValue {
    var ptr_value: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &ptr_value, func_data[0]) < 0) return qjs.exceptionValue();
    const function: *const Function = @ptrFromInt(@as(usize, @bitCast(ptr_value)));

    var frame = CallFrame.init(ctx, argc, argv);
    const alloc = runtime_allocator.allocator();
    var data = ContextData{ .allocator = alloc, .frame = &frame };
    var context = Context{ .api = &context_api, .data = &data };

    const argc_usize: usize = @intCast(@max(argc, 0));
    var handles_buf: [32]Value = undefined;
    const handles = if (argc_usize <= handles_buf.len)
        handles_buf[0..argc_usize]
    else
        alloc.alloc(Value, argc_usize) catch return qjs.exceptionValue();
    defer if (argc_usize > handles_buf.len) alloc.free(handles);
    for (handles, 0..) |*handle, idx| handle.* = idx + 1;

    const returned = function.callback(&context, argc, handles.ptr);
    const value = frame.toJsValueConst(returned) orelse {
        frame.deinit(alloc);
        return qjs.exceptionValue();
    };
    const result = qjs.dupValue(ctx, value);
    frame.deinit(alloc);
    return result;
}

test "native abi creates a callable function module" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const function = Function{
        .name = "answer",
        .callback = struct {
            fn call(ctx: *Context, _: c_int, _: [*c]const Value) callconv(.c) Value {
                return ctx.api.int32_value(ctx, 42);
            }
        }.call,
        .length = 0,
    };
    const functions = [_]Function{function};
    const module_descriptor = Module{ .specifier = "demo:native", .functions = &functions, .function_count = functions.len };
    var collector = ModuleCollector.init(std.testing.allocator);
    defer collector.deinit();
    try collector.addModule(&module_descriptor);
    const module = createFunctionModule(std.heap.page_allocator, runtime.ctx, "demo:native", collector.modules.items[0].functions);
    try std.testing.expect(module != null);
}

test "native abi exposes metric helpers to callbacks" {
    telemetry_metrics.clear();
    defer telemetry_metrics.clear();

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const function = Function{
        .name = "record",
        .callback = struct {
            fn call(ctx: *Context, _: c_int, _: [*c]const Value) callconv(.c) Value {
                const definition = MetricDefinition{
                    .scope = "addon.test",
                    .name = "calls",
                    .kind = @intFromEnum(telemetry_metrics.Kind.counter),
                    .unit = "count",
                };
                var id: u32 = 0;
                if (ctx.api.metric_register(ctx, &definition, &id) != 0) return ctx.api.throw_error(ctx, "metric register failed");
                if (ctx.api.metric_add(ctx, id, 1) != 0) return ctx.api.throw_error(ctx, "metric add failed");
                var current: f64 = 0;
                if (ctx.api.metric_value(ctx, id, &current) != 0) return ctx.api.throw_error(ctx, "metric value failed");
                return ctx.api.float64_value(ctx, current);
            }
        }.call,
        .length = 0,
    };
    var argv: [1]qjs.c.JSValueConst = undefined;
    var handles: [1]Value = undefined;
    var frame = CallFrame.init(runtime.ctx, 0, &argv);
    var data = ContextData{ .allocator = std.testing.allocator, .frame = &frame };
    var context = Context{ .api = &context_api, .data = &data };
    _ = function.callback(&context, 0, &handles);
    frame.deinit(std.testing.allocator);

    var buffer: [telemetry_metrics.max_metrics]telemetry_metrics.Snapshot = undefined;
    const view = telemetry_metrics.snapshot(&buffer);
    try std.testing.expectEqual(@as(usize, 1), view.len);
    try std.testing.expectEqualStrings("addon.test", view[0].scope);
    try std.testing.expectEqualStrings("calls", view[0].name);
    try std.testing.expectEqual(@as(f64, 1), view[0].value);
}
