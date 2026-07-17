const std = @import("std");
const native_module = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const specifier: [:0]const u8 = "hao:process/native";

const alloc = std.heap.page_allocator;
var current_io: ?std.Io = null;

const functions = [_]native_module.LegacyFunction{
    .{ .name = "runNative", .function = jsRunNative, .length = 1 },
    .{ .name = "getEnvNative", .function = jsGetEnvNative, .length = 1 },
};

pub fn attachIo(io: std.Io) void {
    current_io = io;
}

pub fn detachIo() void {
    current_io = null;
}

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return native_module.createLegacyFunctionModule(ctx, module_name, init, &functions);
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    return native_module.bindLegacyFunctionExports(ctx, module, &functions);
}

fn jsGetEnvNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 1) return qjs.exceptionValue();
    const name = qjs.valueToStringAlloc(ctx, argv[0], alloc) catch return qjs.exceptionValue();
    defer alloc.free(name);
    const name_z = alloc.dupeZ(u8, name) catch return qjs.exceptionValue();
    defer alloc.free(name_z);

    const value = c.getenv(name_z.ptr) orelse return qjs.nullValue(ctx);
    return qjs.createString(ctx, std.mem.span(value));
}

fn throwType(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowTypeError(ctx, message.ptr);
}

fn throwInternal(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowInternalError(ctx, message.ptr);
}

fn getPropertyOwned(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: [:0]const u8) qjs.c.JSValue {
    return qjs.getProperty(ctx, object, key);
}

fn optionalStringProp(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: [:0]const u8) !?[]u8 {
    const value = getPropertyOwned(ctx, object, key);
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return null;
    return try qjs.valueToStringAlloc(ctx, value, alloc);
}

fn requiredStringProp(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: [:0]const u8) ![]u8 {
    return (try optionalStringProp(ctx, object, key)) orelse return error.MissingStringProperty;
}

fn optionalPositiveUsizeProp(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: [:0]const u8, default: usize) !usize {
    const value = getPropertyOwned(ctx, object, key);
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return default;
    var out: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &out, value) < 0 or out <= 0) return error.InvalidNumberProperty;
    return @intCast(out);
}

fn parseArgs(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst) ![][]const u8 {
    const value = getPropertyOwned(ctx, object, "args");
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return alloc.alloc([]const u8, 0);
    if (!qjs.isArray(ctx, value)) return error.InvalidArgs;

    const length_value = qjs.getProperty(ctx, value, "length");
    defer qjs.freeValue(ctx, length_value);
    var length_i32: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &length_i32, length_value) < 0 or length_i32 < 0) return error.InvalidArgs;
    const length: usize = @intCast(length_i32);

    const out = try alloc.alloc([]const u8, length);
    errdefer alloc.free(out);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |arg| alloc.free(@constCast(arg));
    }

    for (0..length) |index| {
        const item = qjs.c.JS_GetPropertyUint32(ctx, value, @intCast(index));
        defer qjs.freeValue(ctx, item);
        out[index] = try qjs.valueToStringAlloc(ctx, item, alloc);
        built += 1;
    }
    return out;
}

fn freeArgs(args: [][]const u8) void {
    for (args) |arg| alloc.free(@constCast(arg));
    alloc.free(args);
}

fn termFields(term: std.process.Child.Term) struct { exit_code: ?u32, signal: ?u32 } {
    return switch (term) {
        .exited => |code| .{ .exit_code = code, .signal = null },
        .signal => |sig| .{ .exit_code = null, .signal = @intFromEnum(sig) },
        .stopped => |sig| .{ .exit_code = null, .signal = @intFromEnum(sig) },
        .unknown => |code| .{ .exit_code = null, .signal = code },
    };
}

fn makeRunResult(ctx: ?*qjs.c.JSContext, result: std.process.RunResult) qjs.c.JSValue {
    const out = qjs.newObject(ctx);
    if (qjs.isException(out)) return out;

    qjs.setProperty(ctx, out, "stdout", qjs.createString(ctx, result.stdout)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, out, "stderr", qjs.createString(ctx, result.stderr)) catch return qjs.exceptionValue();
    const term = termFields(result.term);
    qjs.setProperty(ctx, out, "exitCode", if (term.exit_code) |code| qjs.c.JS_NewInt32(ctx, @intCast(code)) else qjs.nullValue(ctx)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, out, "signal", if (term.signal) |sig| qjs.c.JS_NewInt32(ctx, @intCast(sig)) else qjs.nullValue(ctx)) catch return qjs.exceptionValue();
    return out;
}

fn jsRunNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const io = current_io orelse return throwInternal(ctx, "process.run requires attached IO");
    if (argc < 1 or !qjs.isObject(argv[0])) return throwType(ctx, "process.run requires an options object");

    const cmd = requiredStringProp(ctx, argv[0], "cmd") catch return throwType(ctx, "process.run requires options.cmd");
    defer alloc.free(cmd);
    const args = parseArgs(ctx, argv[0]) catch return throwType(ctx, "process.run args must be a string array");
    defer freeArgs(args);
    const cwd = optionalStringProp(ctx, argv[0], "cwd") catch return throwType(ctx, "process.run cwd must be a string");
    defer if (cwd) |path| alloc.free(path);
    const max_output_bytes = optionalPositiveUsizeProp(ctx, argv[0], "maxOutputBytes", 1024 * 1024) catch return throwType(ctx, "process.run maxOutputBytes must be positive");

    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(alloc);
    argv_list.append(alloc, cmd) catch return qjs.c.JS_ThrowOutOfMemory(ctx);
    for (args) |arg| argv_list.append(alloc, arg) catch return qjs.c.JS_ThrowOutOfMemory(ctx);

    const result = std.process.run(alloc, io, .{
        .argv = argv_list.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    }) catch return throwInternal(ctx, "process.run failed");
    defer {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
    }

    return makeRunResult(ctx, result);
}

test "hao process native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
