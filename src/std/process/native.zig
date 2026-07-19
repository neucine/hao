const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs_test = @import("../../qjs.zig");
const runtime_allocator = @import("../../runtime_allocator.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const specifier: [:0]const u8 = "std:process/native";

const alloc = runtime_allocator.allocator();
var current_io: ?std.Io = null;

const functions = [_]js_abi.Function{
    .{ .name = "runNative", .callback = jsRunNative, .length = 1 },
    .{ .name = "getEnvNative", .callback = jsGetEnvNative, .length = 1 },
    .{ .name = null, .callback = jsGetEnvNative },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
    &functions[1],
};

pub fn attachIo(io: std.Io) void {
    current_io = io;
}

pub fn detachIo() void {
    current_io = null;
}

pub fn load(ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque {
    return @ptrCast(js_abi.createFunctionModule(runtime_allocator.allocator(), @ptrCast(ctx), module_name, &function_ptrs));
}

fn valueString(ctx: *js_abi.Context, value: js_abi.Value) ?[]const u8 {
    return std.mem.span(ctx.api.to_string(ctx, value) orelse return null);
}

fn stringArg(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value, index: usize) ?[]const u8 {
    if (argc <= index) return null;
    return valueString(ctx, argv[index]);
}

fn jsGetEnvNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const name = stringArg(ctx, argc, argv, 0) orelse return ctx.api.throw_type_error(ctx, "getEnvNative expects a variable name");
    const name_z = alloc.dupeZ(u8, name) catch return throwInternalAbi(ctx, "out of memory");
    defer alloc.free(name_z);

    const value = c.getenv(name_z.ptr) orelse return ctx.api.null_value(ctx);
    return ctx.api.string_value(ctx, value);
}

fn throwTypeAbi(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_type_error(ctx, message);
}

fn throwInternalAbi(ctx: *js_abi.Context, message: [*:0]const u8) js_abi.Value {
    return ctx.api.throw_error(ctx, message);
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

fn setStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, value: []const u8) !void {
    const value_z = try alloc.dupeZ(u8, value);
    defer alloc.free(value_z);
    if (ctx.api.set_property(ctx, object, key, ctx.api.string_value(ctx, value_z.ptr)) < 0) return error.JavaScriptError;
}

fn setNullableIntProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, maybe_value: ?u32) !void {
    const value = if (maybe_value) |v| ctx.api.int32_value(ctx, @intCast(v)) else ctx.api.null_value(ctx);
    if (ctx.api.set_property(ctx, object, key, value) < 0) return error.JavaScriptError;
}

fn makeRunResult(ctx: *js_abi.Context, result: std.process.RunResult) js_abi.Value {
    const out = ctx.api.object_value(ctx);

    setStringProp(ctx, out, "stdout", result.stdout) catch return throwInternalAbi(ctx, "failed to create process result");
    setStringProp(ctx, out, "stderr", result.stderr) catch return throwInternalAbi(ctx, "failed to create process result");
    const term = termFields(result.term);
    setNullableIntProp(ctx, out, "exitCode", term.exit_code) catch return throwInternalAbi(ctx, "failed to create process result");
    setNullableIntProp(ctx, out, "signal", term.signal) catch return throwInternalAbi(ctx, "failed to create process result");
    return out;
}

fn isMissing(ctx: *js_abi.Context, value: js_abi.Value) bool {
    return ctx.api.is_undefined(ctx, value) != 0 or ctx.api.is_null(ctx, value) != 0;
}

fn getProperty(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8) js_abi.Value {
    return ctx.api.get_property(ctx, object, key);
}

fn optionalStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8) !?[]const u8 {
    const value = getProperty(ctx, object, key);
    if (isMissing(ctx, value)) return null;
    return valueString(ctx, value) orelse error.InvalidStringProperty;
}

fn requiredStringProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8) ![]const u8 {
    return (try optionalStringProp(ctx, object, key)) orelse return error.MissingStringProperty;
}

fn optionalPositiveUsizeProp(ctx: *js_abi.Context, object: js_abi.Value, key: [*:0]const u8, default: usize) !usize {
    const value = getProperty(ctx, object, key);
    if (isMissing(ctx, value)) return default;
    var out: i32 = 0;
    if (ctx.api.to_int32(ctx, value, &out) < 0 or out <= 0) return error.InvalidNumberProperty;
    return @intCast(out);
}

fn parseArgs(ctx: *js_abi.Context, object: js_abi.Value) ![][]const u8 {
    const value = getProperty(ctx, object, "args");
    if (isMissing(ctx, value)) return alloc.alloc([]const u8, 0);
    if (ctx.api.is_array(ctx, value) == 0) return error.InvalidArgs;

    var length_u32: u32 = 0;
    if (ctx.api.array_length(ctx, value, &length_u32) < 0) return error.InvalidArgs;
    const length: usize = @intCast(length_u32);

    const out = try alloc.alloc([]const u8, length);
    errdefer alloc.free(out);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |arg| alloc.free(@constCast(arg));
    }

    for (0..length) |index| {
        const item = ctx.api.array_get(ctx, value, @intCast(index));
        out[index] = try alloc.dupe(u8, valueString(ctx, item) orelse return error.InvalidArgs);
        built += 1;
    }
    return out;
}

fn jsRunNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const io = current_io orelse return throwInternalAbi(ctx, "process.run requires attached IO");
    if (argc < 1 or ctx.api.is_object(ctx, argv[0]) == 0) return throwTypeAbi(ctx, "process.run requires an options object");

    const cmd = requiredStringProp(ctx, argv[0], "cmd") catch return throwTypeAbi(ctx, "process.run requires options.cmd");
    const args = parseArgs(ctx, argv[0]) catch return throwTypeAbi(ctx, "process.run args must be a string array");
    defer freeArgs(args);
    const cwd = optionalStringProp(ctx, argv[0], "cwd") catch return throwTypeAbi(ctx, "process.run cwd must be a string");
    const max_output_bytes = optionalPositiveUsizeProp(ctx, argv[0], "maxOutputBytes", 1024 * 1024) catch return throwTypeAbi(ctx, "process.run maxOutputBytes must be positive");

    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(alloc);
    argv_list.append(alloc, cmd) catch return throwInternalAbi(ctx, "out of memory");
    for (args) |arg| argv_list.append(alloc, arg) catch return throwInternalAbi(ctx, "out of memory");

    const result = std.process.run(alloc, io, .{
        .argv = argv_list.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    }) catch return throwInternalAbi(ctx, "process.run failed");
    defer {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
    }

    return makeRunResult(ctx, result);
}

test "std process native module can be created" {
    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
