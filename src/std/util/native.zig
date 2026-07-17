const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");

pub const specifier: [:0]const u8 = "std:util/native";

const alloc = std.heap.page_allocator;

pub const InspectOptions = struct {
    max_depth: usize = 4,
    max_array_length: usize = 100,
    max_string_length: usize = 10000,
};

pub var defaults = InspectOptions{};

const functions = [_]js_abi.Function{
    .{ .name = "inspect", .callback = js_inspect, .length = 2 },
    .{ .name = "setInspectOptions", .callback = js_setInspectOptions, .length = 1 },
    .{ .name = "getInspectOptions", .callback = js_getInspectOptions, .length = 0 },
    .{ .name = null, .callback = js_getInspectOptions },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
    &functions[1],
    &functions[2],
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &function_ptrs);
}

fn isInfinity(n: f64) bool {
    return std.math.isInf(n);
}

fn clampLimit(n: f64) usize {
    if (isInfinity(n)) return std.math.maxInt(usize);
    if (n <= 0) return 0;
    if (n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(n);
}

fn getNumberProp(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, name: [:0]const u8) ?f64 {
    const val = qjs.getProperty(ctx, obj, name);
    defer qjs.freeValue(ctx, val);
    if (qjs.isUndefined(val) or qjs.isNull(val) or !qjs.isNumber(val)) return null;
    var out: f64 = 0;
    if (qjs.c.JS_ToFloat64(ctx, &out, val) < 0) return null;
    return out;
}

fn mergeOptions(ctx: ?*qjs.c.JSContext, opts_val: qjs.c.JSValueConst) InspectOptions {
    var o = defaults;
    if (!qjs.isObject(opts_val)) return o;
    if (getNumberProp(ctx, opts_val, "maxDepth")) |v| o.max_depth = clampLimit(v);
    if (getNumberProp(ctx, opts_val, "maxArrayLength")) |v| o.max_array_length = clampLimit(v);
    if (getNumberProp(ctx, opts_val, "maxStringLength")) |v| o.max_string_length = clampLimit(v);
    return o;
}

fn makeDefaultsObject(ctx: ?*qjs.c.JSContext) qjs.c.JSValue {
    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj)) return obj;
    const max_depth = if (defaults.max_depth == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_depth));
    const max_array = if (defaults.max_array_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_array_length));
    const max_string = if (defaults.max_string_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_string_length));
    qjs.setProperty(ctx, obj, "maxDepth", qjs.c.JS_NewFloat64(ctx, max_depth)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "maxArrayLength", qjs.c.JS_NewFloat64(ctx, max_array)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "maxStringLength", qjs.c.JS_NewFloat64(ctx, max_string)) catch return qjs.exceptionValue();
    return obj;
}

fn makeDefaultsObjectAbi(ctx: *js_abi.Context) js_abi.Value {
    const obj = ctx.api.object_value(ctx);
    const max_depth = if (defaults.max_depth == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_depth));
    const max_array = if (defaults.max_array_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_array_length));
    const max_string = if (defaults.max_string_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_string_length));
    if (ctx.api.set_property(ctx, obj, "maxDepth", ctx.api.float64_value(ctx, max_depth)) < 0) return ctx.api.throw_error(ctx, "failed to create inspect options");
    if (ctx.api.set_property(ctx, obj, "maxArrayLength", ctx.api.float64_value(ctx, max_array)) < 0) return ctx.api.throw_error(ctx, "failed to create inspect options");
    if (ctx.api.set_property(ctx, obj, "maxStringLength", ctx.api.float64_value(ctx, max_string)) < 0) return ctx.api.throw_error(ctx, "failed to create inspect options");
    return obj;
}

fn appendSlice(buf: *std.ArrayList(u8), s: []const u8) void {
    buf.appendSlice(alloc, s) catch {};
}

fn appendValueString(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) void {
    const text = qjs.valueToStringAlloc(ctx, value, alloc) catch return;
    defer alloc.free(text);
    appendSlice(buf, text);
}

fn appendStringTruncated(buf: *std.ArrayList(u8), value: []const u8, max_len: usize) void {
    if (max_len == std.math.maxInt(usize) or value.len <= max_len) {
        appendSlice(buf, value);
        return;
    }
    appendSlice(buf, value[0..max_len]);
    appendSlice(buf, "...");
}

fn objectHasReprMethod(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, name: [:0]const u8) bool {
    const repr_val = qjs.getProperty(ctx, obj, name);
    defer qjs.freeValue(ctx, repr_val);
    return qjs.isObject(repr_val) and qjs.isFunction(ctx, repr_val);
}

fn objectHasRepr(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst) bool {
    return objectHasReprMethod(ctx, obj, "repr");
}

fn formatReprData(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, opts: InspectOptions) bool {
    if (!objectHasRepr(ctx, obj)) return false;
    const repr_fn = qjs.getProperty(ctx, obj, "repr");
    defer qjs.freeValue(ctx, repr_fn);
    const repr_opts = qjs.newObject(ctx);
    if (qjs.isException(repr_opts)) return false;
    defer qjs.freeValue(ctx, repr_opts);
    qjs.setProperty(ctx, repr_opts, "mode", qjs.createString(ctx, "text")) catch return false;
    const args = [_]qjs.c.JSValueConst{repr_opts};
    const result = qjs.call(ctx, repr_fn, obj, &args);
    defer qjs.freeValue(ctx, result);
    if (qjs.isException(result)) return false;
    if (qjs.isObject(result)) {
        const data = qjs.getProperty(ctx, result, "data");
        defer qjs.freeValue(ctx, data);
        if (qjs.isUndefined(data) or qjs.isNull(data)) return false;
        const text = qjs.valueToStringAlloc(ctx, data, alloc) catch return false;
        defer alloc.free(text);
        appendStringTruncated(buf, text, opts.max_string_length);
        return true;
    }
    const text = qjs.valueToStringAlloc(ctx, result, alloc) catch return false;
    defer alloc.free(text);
    appendStringTruncated(buf, text, opts.max_string_length);
    return true;
}

fn looksLikeHaoArrayLike(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst) bool {
    const dtype = qjs.getProperty(ctx, obj, "dtype");
    defer qjs.freeValue(ctx, dtype);
    if (qjs.isUndefined(dtype) or qjs.isNull(dtype)) return false;

    const shape = qjs.getProperty(ctx, obj, "shape");
    defer qjs.freeValue(ctx, shape);
    if (qjs.isUndefined(shape) or qjs.isNull(shape)) return false;

    const to_string = qjs.getProperty(ctx, obj, "toString");
    defer qjs.freeValue(ctx, to_string);
    return qjs.isFunction(ctx, to_string);
}

fn formatFunction(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst) void {
    const name_val = qjs.getProperty(ctx, obj, "name");
    defer qjs.freeValue(ctx, name_val);
    if (qjs.isString(name_val)) {
        const name = qjs.valueToStringAlloc(ctx, name_val, alloc) catch {
            appendSlice(buf, "[Function]");
            return;
        };
        defer alloc.free(name);
        if (name.len > 0) {
            appendSlice(buf, "[Function: ");
            appendSlice(buf, name);
            appendSlice(buf, "]");
            return;
        }
    }
    appendSlice(buf, "[Function]");
}

fn seenContains(seen: *std.ArrayList(usize), raw: usize) bool {
    for (seen.items) |item| {
        if (item == raw) return true;
    }
    return false;
}

fn isArray(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) bool {
    const array_ctor = qjs.eval(ctx, "Array.isArray", "<std:util>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, array_ctor);
    if (qjs.isException(array_ctor) or !qjs.isFunction(ctx, array_ctor)) return false;
    const args = [_]qjs.c.JSValueConst{value};
    const result = qjs.call(ctx, array_ctor, qjs.undefinedValue(ctx), &args);
    defer qjs.freeValue(ctx, result);
    return qjs.c.JS_ToBool(ctx, result) == 1;
}

fn getPropertyOwned(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: []const u8) qjs.c.JSValue {
    const z = alloc.dupeZ(u8, key) catch return qjs.undefinedValue(ctx);
    defer alloc.free(z);
    return qjs.getProperty(ctx, object, z);
}

fn formatArray(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    appendSlice(buf, "[ ");
    const len_val = qjs.getProperty(ctx, value, "length");
    defer qjs.freeValue(ctx, len_val);
    var len_i32: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &len_i32, len_val) < 0 or len_i32 < 0) len_i32 = 0;
    const len: usize = @intCast(len_i32);
    const limit = if (opts.max_array_length == std.math.maxInt(usize)) len else @min(len, opts.max_array_length);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (i > 0) appendSlice(buf, ", ");
        const item = qjs.c.JS_GetPropertyUint32(ctx, value, @intCast(i));
        defer qjs.freeValue(ctx, item);
        formatValue(buf, ctx, item, opts, depth + 1, seen);
    }
    if (len > limit) {
        if (limit > 0) appendSlice(buf, ", ");
        var tmp: [64]u8 = undefined;
        const more = len - limit;
        const slice = std.fmt.bufPrint(&tmp, "... {d} more items", .{more}) catch "";
        if (slice.len > 0) appendSlice(buf, slice);
    }
    appendSlice(buf, " ]");
}

fn formatObject(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    appendSlice(buf, "{ ");
    const keys_fn = qjs.eval(ctx, "Object.keys", "<std:util>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, keys_fn);
    if (qjs.isException(keys_fn) or !qjs.isFunction(ctx, keys_fn)) {
        appendSlice(buf, "}");
        return;
    }

    const key_args = [_]qjs.c.JSValueConst{value};
    const keys = qjs.call(ctx, keys_fn, qjs.undefinedValue(ctx), &key_args);
    defer qjs.freeValue(ctx, keys);
    if (qjs.isException(keys) or !qjs.isObject(keys)) {
        appendSlice(buf, "}");
        return;
    }

    const len_val = qjs.getProperty(ctx, keys, "length");
    defer qjs.freeValue(ctx, len_val);
    var len_i32: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &len_i32, len_val) < 0 or len_i32 < 0) len_i32 = 0;
    const count: usize = @intCast(len_i32);
    const limit = if (opts.max_array_length == std.math.maxInt(usize)) count else @min(count, opts.max_array_length);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (i > 0) appendSlice(buf, ", ");
        const key_val = qjs.c.JS_GetPropertyUint32(ctx, keys, @intCast(i));
        defer qjs.freeValue(ctx, key_val);
        const key = qjs.valueToStringAlloc(ctx, key_val, alloc) catch continue;
        defer alloc.free(key);
        appendSlice(buf, key);
        appendSlice(buf, ": ");
        const prop_val = getPropertyOwned(ctx, value, key);
        defer qjs.freeValue(ctx, prop_val);
        formatValue(buf, ctx, prop_val, opts, depth + 1, seen);
    }
    if (count > limit) {
        if (limit > 0) appendSlice(buf, ", ");
        var tmp: [64]u8 = undefined;
        const more = count - limit;
        const slice = std.fmt.bufPrint(&tmp, "... {d} more items", .{more}) catch "";
        if (slice.len > 0) appendSlice(buf, slice);
    }
    appendSlice(buf, " }");
}

fn formatValue(buf: *std.ArrayList(u8), ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    if (qjs.isString(value)) {
        const text = qjs.valueToStringAlloc(ctx, value, alloc) catch return;
        defer alloc.free(text);
        appendStringTruncated(buf, text, opts.max_string_length);
        return;
    }
    if (qjs.isNull(value)) {
        appendSlice(buf, "null");
        return;
    }
    if (qjs.isUndefined(value)) {
        appendSlice(buf, "undefined");
        return;
    }
    if (qjs.isBool(value) or qjs.isNumber(value) or qjs.isSymbol(value)) {
        appendValueString(buf, ctx, value);
        return;
    }
    if (!qjs.isObject(value)) {
        appendValueString(buf, ctx, value);
        return;
    }

    if (depth >= opts.max_depth) {
        appendSlice(buf, "[Object]");
        return;
    }
    if (formatReprData(buf, ctx, value, opts)) return;
    if (looksLikeHaoArrayLike(ctx, value)) {
        appendValueString(buf, ctx, value);
        return;
    }
    if (qjs.isFunction(ctx, value)) {
        formatFunction(buf, ctx, value);
        return;
    }

    const raw = @intFromPtr(qjs.c.JS_VALUE_GET_PTR(value));
    if (seenContains(seen, raw)) {
        appendSlice(buf, "[Circular]");
        return;
    }
    seen.append(alloc, raw) catch return;
    defer _ = seen.pop();

    if (isArray(ctx, value)) {
        formatArray(buf, ctx, value, opts, depth, seen);
    } else {
        formatObject(buf, ctx, value, opts, depth, seen);
    }
}

pub fn inspectAlloc(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    opts_value: ?qjs.c.JSValueConst,
    allocator: std.mem.Allocator,
) ![]u8 {
    const opts = if (opts_value) |opts_val| mergeOptions(ctx, opts_val) else defaults;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var seen: std.ArrayList(usize) = .empty;
    defer seen.deinit(alloc);
    formatValue(&buf, ctx, value, opts, 0, &seen);
    return allocator.dupe(u8, buf.items);
}

fn js_inspect(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc == 0) return ctx.api.undefined(ctx);
    const qjs_ctx = js_abi.borrowContext(ctx);
    const value = js_abi.borrowValue(ctx, argv[0]) orelse return ctx.api.throw_error(ctx, "failed to inspect value");
    const opts = if (argc > 1) js_abi.borrowValue(ctx, argv[1]) else null;
    const text = inspectAlloc(qjs_ctx, value, opts, alloc) catch return ctx.api.throw_error(ctx, "failed to inspect value");
    defer alloc.free(text);
    const text_z = alloc.dupeZ(u8, text) catch return ctx.api.throw_error(ctx, "out of memory");
    defer alloc.free(text_z);
    return ctx.api.string_value(ctx, text_z.ptr);
}

fn js_setInspectOptions(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    if (argc > 0) {
        const qjs_ctx = js_abi.borrowContext(ctx);
        if (js_abi.borrowValue(ctx, argv[0])) |opts| defaults = mergeOptions(qjs_ctx, opts);
    }
    return ctx.api.undefined(ctx);
}

fn js_getInspectOptions(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    return makeDefaultsObjectAbi(ctx);
}

test "util qjs module exports can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier);
    try std.testing.expect(module != null);
}

test "inspect formats arrays and objects" {
    defaults = .{};
    defer defaults = .{};

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const value = qjs.eval(
        runtime.ctx,
        "globalThis.__hao_inspect_value = { xs: [1, 2, 3], ok: true };",
        "<inspect-value>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const global = qjs.c.JS_GetGlobalObject(runtime.ctx);
    defer qjs.freeValue(runtime.ctx, global);
    const obj = qjs.getProperty(runtime.ctx, global, "__hao_inspect_value");
    defer qjs.freeValue(runtime.ctx, obj);

    const text = try inspectAlloc(runtime.ctx, obj, null, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{ xs: [ 1, 2, 3 ], ok: true }", text);
}

test "inspect uses generic repr() data when present" {
    defaults = .{};
    defer defaults = .{};

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const value = qjs.eval(
        runtime.ctx,
        "globalThis.__hao_repr_obj = { repr() { return { mime: 'image/svg+xml', data: '<svg><circle /></svg>' }; } };",
        "<inspect-repr>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const global = qjs.c.JS_GetGlobalObject(runtime.ctx);
    defer qjs.freeValue(runtime.ctx, global);
    const obj = qjs.getProperty(runtime.ctx, global, "__hao_repr_obj");
    defer qjs.freeValue(runtime.ctx, obj);

    const text = try inspectAlloc(runtime.ctx, obj, null, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("<svg><circle /></svg>", text);
}
