const std = @import("std");
const qjs = @import("../qjs.zig");
const runtime_allocator = @import("../runtime_allocator.zig");
const util_qjs = @import("../std/util/native.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

pub const CaptureTarget = enum {
    stdout,
    stderr,
    both,
};

pub const CaptureState = struct {
    target: CaptureTarget,
    stdout: ?*std.ArrayList(u8),
    stderr: ?*std.ArrayList(u8),
};

pub var capture_state: ?CaptureState = null;

fn allocator() std.mem.Allocator {
    return runtime_allocator.allocator();
}

pub fn register(ctx: ?*qjs.c.JSContext) !void {
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const console = qjs.newObject(ctx);
    if (qjs.isException(console)) return error.JavaScriptError;
    defer qjs.freeValue(ctx, console);

    try qjs.setProperty(ctx, console, "log", qjs.c.JS_NewCFunction(ctx, jsConsoleLog, "log", 1));
    try qjs.setProperty(ctx, console, "error", qjs.c.JS_NewCFunction(ctx, jsConsoleError, "error", 1));
    try qjs.setProperty(ctx, console, "warn", qjs.c.JS_NewCFunction(ctx, jsConsoleWarn, "warn", 1));
    try qjs.setProperty(ctx, global, "console", qjs.dupValue(ctx, console));
}

fn writeFile(file: *c.FILE, bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = c.fwrite(bytes.ptr, 1, bytes.len, file);
    _ = c.fflush(file);
}

fn stdoutFile() *c.FILE {
    return switch (@typeInfo(@TypeOf(c.stdout))) {
        .@"fn" => c.stdout(),
        else => c.stdout orelse unreachable,
    };
}

fn stderrFile() *c.FILE {
    return switch (@typeInfo(@TypeOf(c.stderr))) {
        .@"fn" => c.stderr(),
        else => c.stderr orelse unreachable,
    };
}

fn writeStdout(bytes: []const u8) void {
    writeFile(stdoutFile(), bytes);
}

fn writeStderr(bytes: []const u8) void {
    writeFile(stderrFile(), bytes);
}

fn writeCaptured(target: CaptureTarget, bytes: []const u8) void {
    if (capture_state) |state| {
        switch (target) {
            .stdout => {
                if (state.target == .stdout or state.target == .both) {
                    if (state.stdout) |buf| buf.appendSlice(allocator(), bytes) catch {};
                    return;
                }
            },
            .stderr => {
                if (state.target == .stderr or state.target == .both) {
                    if (state.stderr) |buf| buf.appendSlice(allocator(), bytes) catch {};
                    return;
                }
            },
            .both => {},
        }
    }
    switch (target) {
        .stdout => writeStdout(bytes),
        .stderr => writeStderr(bytes),
        .both => unreachable,
    }
}

fn jsConsoleWrite(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst, target: CaptureTarget) qjs.c.JSValue {
    var first = true;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const text = util_qjs.inspectAlloc(ctx, argv[@intCast(i)], null, allocator()) catch {
            return qjs.c.JS_ThrowInternalError(ctx, "console write failed");
        };
        defer allocator().free(text);
        if (!first) writeCaptured(target, " ");
        first = false;
        writeCaptured(target, text);
    }
    writeCaptured(target, "\n");
    return qjs.undefinedValue(ctx);
}

fn jsConsoleLog(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return jsConsoleWrite(ctx, argc, argv, .stdout);
}

fn jsConsoleError(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return jsConsoleWrite(ctx, argc, argv, .stderr);
}

fn jsConsoleWarn(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return jsConsoleWrite(ctx, argc, argv, .stderr);
}

test "console global installs" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    try register(runtime.ctx);

    const value = qjs.eval(
        runtime.ctx,
        "typeof console.log === 'function' && typeof console.error === 'function' && typeof console.warn === 'function'",
        "<console-qjs>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(runtime.ctx, value));
}
