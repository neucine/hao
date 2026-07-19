const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs_test = @import("../../qjs.zig");
const runtime_allocator = @import("../../runtime_allocator.zig");

pub const specifier: [:0]const u8 = "std:util/native";

const alloc = runtime_allocator.allocator();

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

pub fn load(ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque {
    return @ptrCast(js_abi.createFunctionModule(runtime_allocator.allocator(), @ptrCast(ctx), module_name, &function_ptrs));
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

fn getNumberProp(ctx: js_abi.JSContext, obj: js_abi.JSValueConst, name: [:0]const u8) ?f64 {
    const val = js_abi.jsGetProperty(ctx, obj, name);
    defer js_abi.jsFreeValue(ctx, val);
    if (js_abi.jsIsUndefined(val) or js_abi.jsIsNull(val) or !js_abi.jsIsNumber(val)) return null;
    var out: f64 = 0;
    if (js_abi.jsToFloat64(ctx, &out, val) < 0) return null;
    return out;
}

fn mergeOptions(ctx: js_abi.JSContext, opts_val: js_abi.JSValueConst) InspectOptions {
    var o = defaults;
    if (!js_abi.jsIsObject(opts_val)) return o;
    if (getNumberProp(ctx, opts_val, "maxDepth")) |v| o.max_depth = clampLimit(v);
    if (getNumberProp(ctx, opts_val, "maxArrayLength")) |v| o.max_array_length = clampLimit(v);
    if (getNumberProp(ctx, opts_val, "maxStringLength")) |v| o.max_string_length = clampLimit(v);
    return o;
}

fn makeDefaultsObject(ctx: js_abi.JSContext) js_abi.JSValue {
    const obj = js_abi.jsNewObject(ctx);
    if (js_abi.jsIsException(obj)) return obj;
    const max_depth = if (defaults.max_depth == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_depth));
    const max_array = if (defaults.max_array_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_array_length));
    const max_string = if (defaults.max_string_length == std.math.maxInt(usize)) std.math.inf(f64) else @as(f64, @floatFromInt(defaults.max_string_length));
    if (js_abi.jsSetProperty(ctx, obj, "maxDepth", js_abi.jsFloat64(ctx, max_depth)) < 0) return js_abi.jsExceptionValue();
    if (js_abi.jsSetProperty(ctx, obj, "maxArrayLength", js_abi.jsFloat64(ctx, max_array)) < 0) return js_abi.jsExceptionValue();
    if (js_abi.jsSetProperty(ctx, obj, "maxStringLength", js_abi.jsFloat64(ctx, max_string)) < 0) return js_abi.jsExceptionValue();
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

fn appendValueString(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, value: js_abi.JSValueConst) void {
    const text = js_abi.jsStringAlloc(ctx, value, alloc) catch return;
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

fn objectHasReprMethod(ctx: js_abi.JSContext, obj: js_abi.JSValueConst, name: [:0]const u8) bool {
    const repr_val = js_abi.jsGetProperty(ctx, obj, name);
    defer js_abi.jsFreeValue(ctx, repr_val);
    return js_abi.jsIsObject(repr_val) and js_abi.jsIsFunction(ctx, repr_val);
}

fn objectHasRepr(ctx: js_abi.JSContext, obj: js_abi.JSValueConst) bool {
    return objectHasReprMethod(ctx, obj, "repr");
}

fn formatReprData(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, obj: js_abi.JSValueConst, opts: InspectOptions) bool {
    if (!objectHasRepr(ctx, obj)) return false;
    const repr_fn = js_abi.jsGetProperty(ctx, obj, "repr");
    defer js_abi.jsFreeValue(ctx, repr_fn);
    const repr_opts = js_abi.jsNewObject(ctx);
    if (js_abi.jsIsException(repr_opts)) return false;
    defer js_abi.jsFreeValue(ctx, repr_opts);
    if (js_abi.jsSetProperty(ctx, repr_opts, "mode", js_abi.jsString(ctx, "text")) < 0) return false;
    const args = [_]js_abi.JSValueConst{repr_opts};
    const result = js_abi.jsCall(ctx, repr_fn, obj, &args);
    defer js_abi.jsFreeValue(ctx, result);
    if (js_abi.jsIsException(result)) return false;
    if (js_abi.jsIsObject(result)) {
        const data = js_abi.jsGetProperty(ctx, result, "data");
        defer js_abi.jsFreeValue(ctx, data);
        if (js_abi.jsIsUndefined(data) or js_abi.jsIsNull(data)) return false;
        const text = js_abi.jsStringAlloc(ctx, data, alloc) catch return false;
        defer alloc.free(text);
        appendStringTruncated(buf, text, opts.max_string_length);
        return true;
    }
    const text = js_abi.jsStringAlloc(ctx, result, alloc) catch return false;
    defer alloc.free(text);
    appendStringTruncated(buf, text, opts.max_string_length);
    return true;
}

fn looksLikeHaoArrayLike(ctx: js_abi.JSContext, obj: js_abi.JSValueConst) bool {
    const dtype = js_abi.jsGetProperty(ctx, obj, "dtype");
    defer js_abi.jsFreeValue(ctx, dtype);
    if (js_abi.jsIsUndefined(dtype) or js_abi.jsIsNull(dtype)) return false;

    const shape = js_abi.jsGetProperty(ctx, obj, "shape");
    defer js_abi.jsFreeValue(ctx, shape);
    if (js_abi.jsIsUndefined(shape) or js_abi.jsIsNull(shape)) return false;

    const to_string = js_abi.jsGetProperty(ctx, obj, "toString");
    defer js_abi.jsFreeValue(ctx, to_string);
    return js_abi.jsIsFunction(ctx, to_string);
}

fn formatFunction(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, obj: js_abi.JSValueConst) void {
    const name_val = js_abi.jsGetProperty(ctx, obj, "name");
    defer js_abi.jsFreeValue(ctx, name_val);
    if (js_abi.jsIsString(name_val)) {
        const name = js_abi.jsStringAlloc(ctx, name_val, alloc) catch {
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

fn isArray(ctx: js_abi.JSContext, value: js_abi.JSValueConst) bool {
    const array_ctor = js_abi.jsEvalGlobal(ctx, "Array.isArray", "<std:util>");
    defer js_abi.jsFreeValue(ctx, array_ctor);
    if (js_abi.jsIsException(array_ctor) or !js_abi.jsIsFunction(ctx, array_ctor)) return false;
    const args = [_]js_abi.JSValueConst{value};
    const result = js_abi.jsCall(ctx, array_ctor, js_abi.jsUndefined(ctx), &args);
    defer js_abi.jsFreeValue(ctx, result);
    var is_array: bool = false;
    return js_abi.jsToBool(ctx, &is_array, result) == 0 and is_array;
}

fn getPropertyOwned(ctx: js_abi.JSContext, object: js_abi.JSValueConst, key: []const u8) js_abi.JSValue {
    const z = alloc.dupeZ(u8, key) catch return js_abi.jsUndefined(ctx);
    defer alloc.free(z);
    return js_abi.jsGetProperty(ctx, object, z);
}

fn formatArray(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, value: js_abi.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    appendSlice(buf, "[ ");
    const len_val = js_abi.jsGetProperty(ctx, value, "length");
    defer js_abi.jsFreeValue(ctx, len_val);
    var len_i32: i32 = 0;
    if (js_abi.jsToInt32(ctx, &len_i32, len_val) < 0 or len_i32 < 0) len_i32 = 0;
    const len: usize = @intCast(len_i32);
    const limit = if (opts.max_array_length == std.math.maxInt(usize)) len else @min(len, opts.max_array_length);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (i > 0) appendSlice(buf, ", ");
        const item = js_abi.jsGetArrayElement(ctx, value, @intCast(i));
        defer js_abi.jsFreeValue(ctx, item);
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

fn formatObject(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, value: js_abi.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    appendSlice(buf, "{ ");
    const keys_fn = js_abi.jsEvalGlobal(ctx, "Object.keys", "<std:util>");
    defer js_abi.jsFreeValue(ctx, keys_fn);
    if (js_abi.jsIsException(keys_fn) or !js_abi.jsIsFunction(ctx, keys_fn)) {
        appendSlice(buf, "}");
        return;
    }

    const key_args = [_]js_abi.JSValueConst{value};
    const keys = js_abi.jsCall(ctx, keys_fn, js_abi.jsUndefined(ctx), &key_args);
    defer js_abi.jsFreeValue(ctx, keys);
    if (js_abi.jsIsException(keys) or !js_abi.jsIsObject(keys)) {
        appendSlice(buf, "}");
        return;
    }

    const len_val = js_abi.jsGetProperty(ctx, keys, "length");
    defer js_abi.jsFreeValue(ctx, len_val);
    var len_i32: i32 = 0;
    if (js_abi.jsToInt32(ctx, &len_i32, len_val) < 0 or len_i32 < 0) len_i32 = 0;
    const count: usize = @intCast(len_i32);
    const limit = if (opts.max_array_length == std.math.maxInt(usize)) count else @min(count, opts.max_array_length);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (i > 0) appendSlice(buf, ", ");
        const key_val = js_abi.jsGetArrayElement(ctx, keys, @intCast(i));
        defer js_abi.jsFreeValue(ctx, key_val);
        const key = js_abi.jsStringAlloc(ctx, key_val, alloc) catch continue;
        defer alloc.free(key);
        appendSlice(buf, key);
        appendSlice(buf, ": ");
        const prop_val = getPropertyOwned(ctx, value, key);
        defer js_abi.jsFreeValue(ctx, prop_val);
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

fn formatValue(buf: *std.ArrayList(u8), ctx: js_abi.JSContext, value: js_abi.JSValueConst, opts: InspectOptions, depth: usize, seen: *std.ArrayList(usize)) void {
    if (js_abi.jsIsString(value)) {
        const text = js_abi.jsStringAlloc(ctx, value, alloc) catch return;
        defer alloc.free(text);
        appendStringTruncated(buf, text, opts.max_string_length);
        return;
    }
    if (js_abi.jsIsNull(value)) {
        appendSlice(buf, "null");
        return;
    }
    if (js_abi.jsIsUndefined(value)) {
        appendSlice(buf, "undefined");
        return;
    }
    if (js_abi.jsIsBool(value) or js_abi.jsIsNumber(value) or js_abi.jsIsSymbol(value)) {
        appendValueString(buf, ctx, value);
        return;
    }
    if (!js_abi.jsIsObject(value)) {
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
    if (js_abi.jsIsFunction(ctx, value)) {
        formatFunction(buf, ctx, value);
        return;
    }

    const raw = js_abi.jsValueIdentity(value);
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
    ctx: js_abi.JSContext,
    value: js_abi.JSValueConst,
    opts_value: ?js_abi.JSValueConst,
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
    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier);
    try std.testing.expect(module != null);
}

test "inspect formats arrays and objects" {
    defaults = .{};
    defer defaults = .{};

    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const value = js_abi.jsEvalGlobal(
        runtime.ctx,
        "globalThis.__hao_inspect_value = { xs: [1, 2, 3], ok: true };",
        "<inspect-value>",
    );
    defer js_abi.jsFreeValue(runtime.ctx, value);
    try std.testing.expect(!js_abi.jsIsException(value));

    const global = js_abi.jsGlobalObject(runtime.ctx);
    defer js_abi.jsFreeValue(runtime.ctx, global);
    const obj = js_abi.jsGetProperty(runtime.ctx, global, "__hao_inspect_value");
    defer js_abi.jsFreeValue(runtime.ctx, obj);

    const text = try inspectAlloc(runtime.ctx, obj, null, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{ xs: [ 1, 2, 3 ], ok: true }", text);
}

test "inspect uses generic repr() data when present" {
    defaults = .{};
    defer defaults = .{};

    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const value = js_abi.jsEvalGlobal(
        runtime.ctx,
        "globalThis.__hao_repr_obj = { repr() { return { mime: 'image/svg+xml', data: '<svg><circle /></svg>' }; } };",
        "<inspect-repr>",
    );
    defer js_abi.jsFreeValue(runtime.ctx, value);
    try std.testing.expect(!js_abi.jsIsException(value));

    const global = js_abi.jsGlobalObject(runtime.ctx);
    defer js_abi.jsFreeValue(runtime.ctx, global);
    const obj = js_abi.jsGetProperty(runtime.ctx, global, "__hao_repr_obj");
    defer js_abi.jsFreeValue(runtime.ctx, obj);

    const text = try inspectAlloc(runtime.ctx, obj, null, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("<svg><circle /></svg>", text);
}
