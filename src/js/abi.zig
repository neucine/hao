const std = @import("std");
const qjs = @import("../qjs.zig");
const telemetry_metrics = @import("../telemetry/metrics.zig");

pub const abi_version: u32 = 2;
pub const register_symbol_name = "js_register_modules";
pub const Value = usize;

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
    try std.testing.expectEqual(@as(usize, ptr_size * 2), @sizeOf(Module));

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

    fn deinit(self: *CallFrame, allocator: std.mem.Allocator, returned: Value) void {
        const argc_usize: usize = @intCast(@max(self.argc, 0));
        for (self.values.items, 0..) |value, idx| {
            const handle: Value = argc_usize + idx + 1;
            if (handle != returned) qjs.freeValue(self.ctx, value);
        }
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
        self.values.append(std.heap.page_allocator, value) catch {};
        const argc_usize: usize = @intCast(@max(self.argc, 0));
        return argc_usize + self.values.items.len;
    }
};

const ContextData = struct {
    allocator: std.mem.Allocator,
    frame: *CallFrame,
};

pub const FunctionModule = struct {
    specifier: [:0]const u8,
    functions: []const *const Function,
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
        var i: usize = 0;
        while (module.functions[i].name != null) : (i += 1) {
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
    qjs.setProperty(data.frame.ctx, js_object, std.mem.span(key), qjs.dupValue(data.frame.ctx, js_value)) catch return -1;
    return 0;
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
    return qjs.c.JS_SetPropertyUint32(data.frame.ctx, js_array, index, qjs.dupValue(data.frame.ctx, js_value));
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
    _: std.mem.Allocator,
    ctx: ?*qjs.c.JSContext,
    module_name: [*c]const u8,
    functions: []const *const Function,
) ?*qjs.c.JSModuleDef {
    if (functions.len == 0) return null;
    const module = qjs.c.JS_NewCModule(ctx, module_name, initFunctionModule) orelse return null;
    _ = qjs.c.JS_SetModulePrivateValue(ctx, module, qjs.c.JS_NewInt64(ctx, @intCast(@intFromPtr(functions[0]))));
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
    const functions: [*]const Function = @ptrFromInt(@as(usize, @intCast(stored_ptr)));
    const exports = qjs.newObject(ctx);
    if (qjs.isException(exports)) return -1;
    defer qjs.freeValue(ctx, exports);

    var i: usize = 0;
    while (functions[i].name != null) : (i += 1) {
        const function = &functions[i];
        var data = [_]qjs.c.JSValue{qjs.c.JS_NewInt64(ctx, @intCast(@intFromPtr(function)))};
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
    const function: *const Function = @ptrFromInt(@as(usize, @intCast(ptr_value)));

    var frame = CallFrame.init(ctx, argc, argv);
    var data = ContextData{ .allocator = std.heap.page_allocator, .frame = &frame };
    var context = Context{ .api = &context_api, .data = &data };

    const argc_usize: usize = @intCast(@max(argc, 0));
    var handles_buf: [32]Value = undefined;
    const handles = if (argc_usize <= handles_buf.len)
        handles_buf[0..argc_usize]
    else
        std.heap.page_allocator.alloc(Value, argc_usize) catch return qjs.exceptionValue();
    defer if (argc_usize > handles_buf.len) std.heap.page_allocator.free(handles);
    for (handles, 0..) |*handle, idx| handle.* = idx + 1;

    const returned = function.callback(&context, argc, handles.ptr);
    defer frame.deinit(std.heap.page_allocator, returned);
    const value = frame.toJsValueConst(returned) orelse return qjs.exceptionValue();
    if (returned > argc_usize) return value;
    return qjs.dupValue(ctx, value);
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
    const functions = [_]Function{ function, .{ .name = null, .callback = function.callback } };
    const module_descriptor = Module{ .specifier = "demo:native", .functions = &functions };
    var collector = ModuleCollector.init(std.testing.allocator);
    defer collector.deinit();
    try collector.addModule(&module_descriptor);
    const module = createFunctionModule(std.testing.allocator, runtime.ctx, "demo:native", collector.modules.items[0].functions);
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
    frame.deinit(std.testing.allocator, 0);

    var buffer: [telemetry_metrics.max_metrics]telemetry_metrics.Snapshot = undefined;
    const view = telemetry_metrics.snapshot(&buffer);
    try std.testing.expectEqual(@as(usize, 1), view.len);
    try std.testing.expectEqualStrings("addon.test", view[0].scope);
    try std.testing.expectEqualStrings("calls", view[0].name);
    try std.testing.expectEqual(@as(f64, 1), view[0].value);
}
