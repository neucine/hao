const std = @import("std");
const config = @import("config.zig");

pub const c = @cImport({
    @cInclude("quickjs.h");
});

var pending_exception_ctx: ?*c.JSContext = null;
var pending_exception_value: ?c.JSValue = null;

pub const ClassSlot = enum {
    file,
    trace_handle,
};

var class_ids = [_]c.JSClassID{0} ** @typeInfo(ClassSlot).@"enum".fields.len;
var class_ready = [_]bool{false} ** @typeInfo(ClassSlot).@"enum".fields.len;

fn ensureClassesRegistered(rt: ?*c.JSRuntime) void {
    inline for (@typeInfo(ClassSlot).@"enum".fields) |field| {
        _ = ensureClassId(rt, @enumFromInt(field.value));
    }
}

pub fn ensureClassId(rt: ?*c.JSRuntime, slot: ClassSlot) c.JSClassID {
    const idx = @intFromEnum(slot);
    if (!class_ready[idx]) {
        _ = c.JS_NewClassID(@ptrCast(rt), &class_ids[idx]);
        class_ready[idx] = true;
    }
    return class_ids[idx];
}

pub const Runtime = struct {
    rt: ?*c.JSRuntime,
    ctx: ?*c.JSContext,

    pub fn init() !Runtime {
        return initWithOptions(config.runtimeOptions());
    }

    pub fn initWithOptions(options: config.RuntimeOptions) !Runtime {
        const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(rt);
        c.JS_SetMaxStackSize(rt, options.qjs_stack_size);
        c.JS_UpdateStackTop(rt);
        c.JS_SetHostPromiseRejectionTracker(rt, onHostPromiseRejection, null);
        ensureClassesRegistered(rt);

        const ctx = c.JS_NewContext(rt) orelse {
            c.JS_FreeRuntime(rt);
            return error.OutOfMemory;
        };

        return .{
            .rt = rt,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.ctx) |ctx| {
            const pending_exception = c.JS_GetException(ctx);
            c.JS_FreeValue(ctx, pending_exception);
            c.JS_FreeContext(ctx);
        }
        if (self.rt) |rt| {
            c.JS_RunGC(rt);
            c.JS_FreeRuntime(rt);
        }
        self.* = .{ .rt = null, .ctx = null };
    }
};

test "runtime deinit releases pending JavaScript exceptions" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    const value = eval(runtime.ctx, "throw new Error('expected failure');", "<exception-test>", EvalFlags.global);
    defer freeValue(runtime.ctx, value);
    try std.testing.expect(isException(value));
}

test "exception formatting preserves JavaScript and native stacks" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    const value = eval(runtime.ctx, "(() => { const error = new Error('expected failure'); error.nativeStack = 'native frame'; throw error; })()", "<exception-format-test>", EvalFlags.global);
    defer freeValue(runtime.ctx, value);
    try std.testing.expect(isException(value));

    const exception = c.JS_GetException(runtime.ctx);
    defer freeValue(runtime.ctx, exception);
    const text = try formatExceptionAlloc(runtime.ctx, exception, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "expected failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Native stack:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "native frame") != null);
}

pub const MemoryUsage = struct {
    malloc_size: usize,
    malloc_limit: usize,
    memory_used_size: usize,
    malloc_count: usize,
    memory_used_count: usize,
    atom_count: usize,
    atom_size: usize,
    str_count: usize,
    str_size: usize,
    obj_count: usize,
    obj_size: usize,
    prop_count: usize,
    prop_size: usize,
    shape_count: usize,
    shape_size: usize,
    js_func_count: usize,
    js_func_size: usize,
    js_func_code_size: usize,
    array_count: usize,
    fast_array_count: usize,
    fast_array_elements: usize,
    binary_object_count: usize,
    binary_object_size: usize,
};

pub fn updateStackTop(rt: ?*c.JSRuntime) void {
    c.JS_UpdateStackTop(rt);
}

pub fn dupValue(ctx: ?*c.JSContext, value: c.JSValue) c.JSValue {
    return c.JS_DupValue(ctx, value);
}

pub fn freeValue(ctx: ?*c.JSContext, value: c.JSValue) void {
    c.JS_FreeValue(ctx, value);
}

pub fn createString(ctx: ?*c.JSContext, value: []const u8) c.JSValue {
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

pub fn newObject(ctx: ?*c.JSContext) c.JSValue {
    return c.JS_NewObject(ctx);
}

fn makeIntValue(tag: c_int, value: i32) c.JSValue {
    var out: c.JSValue = undefined;
    out.u.int32 = value;
    out.tag = @as(i64, @intCast(tag));
    return out;
}

pub fn undefinedValue(_: ?*c.JSContext) c.JSValue {
    return makeIntValue(c.JS_TAG_UNDEFINED, 0);
}

pub fn nullValue(_: ?*c.JSContext) c.JSValue {
    return makeIntValue(c.JS_TAG_NULL, 0);
}

pub fn exceptionValue() c.JSValue {
    return makeIntValue(c.JS_TAG_EXCEPTION, 0);
}

pub fn boolValue(_: ?*c.JSContext, value: bool) c.JSValue {
    return makeIntValue(c.JS_TAG_BOOL, if (value) 1 else 0);
}

pub fn getProperty(ctx: ?*c.JSContext, obj: c.JSValueConst, key: [:0]const u8) c.JSValue {
    return c.JS_GetPropertyStr(ctx, obj, key.ptr);
}

pub fn setProperty(ctx: ?*c.JSContext, obj: c.JSValueConst, key: [:0]const u8, value: c.JSValue) !void {
    if (c.JS_SetPropertyStr(ctx, obj, key.ptr, value) < 0) return error.JavaScriptError;
}

pub fn valueToStringAlloc(ctx: ?*c.JSContext, value: c.JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    const str = c.JS_ToCString(ctx, value) orelse return error.JavaScriptError;
    defer c.JS_FreeCString(ctx, str);
    return allocator.dupe(u8, std.mem.span(str));
}

pub fn getExceptionAlloc(ctx: ?*c.JSContext, allocator: std.mem.Allocator) ![]u8 {
    const exception = c.JS_GetException(ctx);
    defer freeValue(ctx, exception);
    return formatExceptionAlloc(ctx, exception, allocator);
}

pub fn formatExceptionAlloc(ctx: ?*c.JSContext, exception: c.JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    if (!isObject(exception)) return valueToStringAlloc(ctx, exception, allocator);

    const stack = getProperty(ctx, exception, "stack");
    defer freeValue(ctx, stack);
    const message = getProperty(ctx, exception, "message");
    defer freeValue(ctx, message);
    const native_stack = getProperty(ctx, exception, "nativeStack");
    defer freeValue(ctx, native_stack);

    const stack_text = if (!isUndefined(stack) and !isNull(stack)) valueToStringAlloc(ctx, stack, allocator) catch null else null;
    defer if (stack_text) |text| allocator.free(text);
    const message_text = if (!isUndefined(message) and !isNull(message)) valueToStringAlloc(ctx, message, allocator) catch null else null;
    defer if (message_text) |text| allocator.free(text);
    const native = if (!isUndefined(native_stack) and !isNull(native_stack)) valueToStringAlloc(ctx, native_stack, allocator) catch null else null;

    const primary = if (stack_text) |stack_value| blk: {
        if (message_text) |message_value|
            if (std.mem.indexOf(u8, stack_value, message_value) == null)
                break :blk std.fmt.allocPrint(allocator, "{s}\n{s}", .{ message_value, stack_value }) catch return error.OutOfMemory;
        break :blk allocator.dupe(u8, stack_value) catch return error.OutOfMemory;
    } else if (message_text) |message_value|
        allocator.dupe(u8, message_value) catch return error.OutOfMemory
    else
        null;

    if (primary) |text| {
        if (native) |native_text| {
            defer allocator.free(native_text);
            const combined = std.fmt.allocPrint(allocator, "{s}\nNative stack:\n{s}", .{ text, native_text }) catch {
                allocator.free(text);
                return error.OutOfMemory;
            };
            allocator.free(text);
            return combined;
        }
        return text;
    }
    if (native) |native_text| return native_text;
    return valueToStringAlloc(ctx, exception, allocator);
}

pub fn recordUnhandledException(ctx: ?*c.JSContext, exception: c.JSValueConst) void {
    clearUnhandledException();
    pending_exception_ctx = ctx;
    pending_exception_value = dupValue(ctx, exception);
}

pub fn takeUnhandledException() ?struct { ctx: ?*c.JSContext, value: c.JSValue } {
    const value = pending_exception_value orelse return null;
    const ctx = pending_exception_ctx;
    pending_exception_ctx = null;
    pending_exception_value = null;
    return .{ .ctx = ctx, .value = value };
}

pub fn clearUnhandledException() void {
    if (pending_exception_value) |value| {
        freeValue(pending_exception_ctx, value);
    }
    pending_exception_ctx = null;
    pending_exception_value = null;
}

pub const EvalFlags = struct {
    pub const global = @as(c_int, 0);
    pub const module = c.JS_EVAL_TYPE_MODULE;
    pub const module_compile_only = c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY;
};

pub fn eval(ctx: ?*c.JSContext, source: []const u8, filename: []const u8, flags: c_int) c.JSValue {
    updateStackTop(c.JS_GetRuntime(ctx));
    return c.JS_Eval(ctx, source.ptr, source.len, filename.ptr, flags);
}

pub fn call(ctx: ?*c.JSContext, function: c.JSValueConst, this_value: c.JSValueConst, args: []const c.JSValueConst) c.JSValue {
    updateStackTop(c.JS_GetRuntime(ctx));
    return c.JS_Call(ctx, function, this_value, @intCast(args.len), if (args.len == 0) null else @constCast(args.ptr));
}

pub fn isException(value: c.JSValue) bool {
    return c.JS_IsException(value);
}

pub fn isArray(_: ?*c.JSContext, value: c.JSValueConst) bool {
    return c.JS_IsArray(value);
}

pub fn isFunction(ctx: ?*c.JSContext, value: c.JSValueConst) bool {
    return c.JS_IsFunction(ctx, value);
}

pub fn isUndefined(value: c.JSValueConst) bool {
    return c.JS_IsUndefined(value);
}

pub fn isNull(value: c.JSValueConst) bool {
    return c.JS_IsNull(value);
}

pub fn isString(value: c.JSValueConst) bool {
    return c.JS_IsString(value);
}

pub fn isNumber(value: c.JSValueConst) bool {
    return c.JS_IsNumber(value);
}

pub fn isObject(value: c.JSValueConst) bool {
    return c.JS_IsObject(value);
}

pub fn isBool(value: c.JSValueConst) bool {
    return c.JS_IsBool(value);
}

pub fn isSymbol(value: c.JSValueConst) bool {
    return c.JS_IsSymbol(value);
}

pub fn computeMemoryUsage(rt: ?*c.JSRuntime) MemoryUsage {
    var raw: c.JSMemoryUsage = undefined;
    @memset(std.mem.asBytes(&raw), 0);
    c.JS_ComputeMemoryUsage(rt, &raw);
    return .{
        .malloc_size = @intCast(@max(raw.malloc_size, 0)),
        .malloc_limit = @intCast(@max(raw.malloc_limit, 0)),
        .memory_used_size = @intCast(@max(raw.memory_used_size, 0)),
        .malloc_count = @intCast(@max(raw.malloc_count, 0)),
        .memory_used_count = @intCast(@max(raw.memory_used_count, 0)),
        .atom_count = @intCast(@max(raw.atom_count, 0)),
        .atom_size = @intCast(@max(raw.atom_size, 0)),
        .str_count = @intCast(@max(raw.str_count, 0)),
        .str_size = @intCast(@max(raw.str_size, 0)),
        .obj_count = @intCast(@max(raw.obj_count, 0)),
        .obj_size = @intCast(@max(raw.obj_size, 0)),
        .prop_count = @intCast(@max(raw.prop_count, 0)),
        .prop_size = @intCast(@max(raw.prop_size, 0)),
        .shape_count = @intCast(@max(raw.shape_count, 0)),
        .shape_size = @intCast(@max(raw.shape_size, 0)),
        .js_func_count = @intCast(@max(raw.js_func_count, 0)),
        .js_func_size = @intCast(@max(raw.js_func_size, 0)),
        .js_func_code_size = @intCast(@max(raw.js_func_code_size, 0)),
        .array_count = @intCast(@max(raw.array_count, 0)),
        .fast_array_count = @intCast(@max(raw.fast_array_count, 0)),
        .fast_array_elements = @intCast(@max(raw.fast_array_elements, 0)),
        .binary_object_count = @intCast(@max(raw.binary_object_count, 0)),
        .binary_object_size = @intCast(@max(raw.binary_object_size, 0)),
    };
}

pub fn executePendingJobs(rt: ?*c.JSRuntime) !bool {
    var ran_any = false;
    while (true) {
        var job_ctx: ?*c.JSContext = null;
        const rc = c.JS_ExecutePendingJob(rt, &job_ctx);
        if (rc == 0) break;
        if (rc < 0) return error.JavaScriptError;
        ran_any = true;
    }
    return ran_any;
}

fn onHostPromiseRejection(
    ctx: ?*c.JSContext,
    _: c.JSValueConst,
    reason: c.JSValueConst,
    is_handled: bool,
    _: ?*anyopaque,
) callconv(.c) void {
    if (is_handled) {
        clearUnhandledException();
        return;
    }
    recordUnhandledException(ctx, reason);
}

test "basic runtime init" {
    var runtime = try Runtime.init();
    defer runtime.deinit();

    try std.testing.expect(runtime.rt != null);
    try std.testing.expect(runtime.ctx != null);
}
