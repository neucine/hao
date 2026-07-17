const std = @import("std");
const config = @import("config.zig");
const qjs = @import("qjs.zig");

pub const ErrorCode = enum {
    invalid_arg,
    missing_arg,
    shape_mismatch,
    invalid_shape,
    invalid_dtype,
    out_of_memory,
    device_mismatch,
    device_error,
    grad_error,
    io_error,
    cancelled,
    invalid_state,
    unsupported_lowering,
    internal,
    thread_pool_unavailable,
};

pub const Diagnostic = struct {
    const max_len = 1024;
    const truncation_marker = "... (message truncated)";

    message: [max_len]u8 = undefined,
    message_len: usize = 0,

    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const result = std.fmt.bufPrint(&self.message, fmt, args) catch {
            const safe = max_len - truncation_marker.len;
            @memcpy(self.message[safe..], truncation_marker);
            self.message_len = max_len;
            return;
        };
        self.message_len = result.len;
    }

    pub fn slice(self: *const Diagnostic) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn isEmpty(self: *const Diagnostic) bool {
        return self.message_len == 0;
    }
};

threadlocal var current_diagnostic_ptr: ?*Diagnostic = null;

pub const DiagnosticScope = struct {
    previous: ?*Diagnostic,

    pub fn enter(diag: *Diagnostic) DiagnosticScope {
        const scope: DiagnosticScope = .{ .previous = current_diagnostic_ptr };
        current_diagnostic_ptr = diag;
        return scope;
    }

    pub fn exit(self: *DiagnosticScope) void {
        current_diagnostic_ptr = self.previous;
        self.* = undefined;
    }
};

pub fn currentDiagnostic() ?*Diagnostic {
    return current_diagnostic_ptr;
}

pub fn setCurrentDiagnostic(diag: ?*Diagnostic) ?*Diagnostic {
    const previous = current_diagnostic_ptr;
    current_diagnostic_ptr = diag;
    return previous;
}

pub fn nativeError(err: anyerror, diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) anyerror {
    if (diag) |d| d.set(fmt, args);
    return err;
}

pub fn nativeErrorWithCurrent(err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
    return nativeError(err, current_diagnostic_ptr, fmt, args);
}

pub fn registerRuntimeError(ctx: ?*qjs.c.JSContext, allocator: std.mem.Allocator) !void {
    const source =
        \\if (typeof globalThis.RuntimeError !== 'function') {
        \\  globalThis.RuntimeError = class RuntimeError extends Error {
        \\    constructor(code, message) {
        \\      super(message);
        \\      this.name = 'RuntimeError';
        \\      this.code = code;
        \\    }
        \\  };
        \\}
    ;

    const value = qjs.eval(ctx, source, "<hao:global>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, value);
    if (qjs.isException(value)) {
        const message = qjs.getExceptionAlloc(ctx, allocator) catch return error.JavaScriptError;
        defer allocator.free(message);
        std.log.err("quickjs global init failed: {s}", .{message});
        return error.JavaScriptError;
    }
}

pub fn jsError(
    ctx: ?*qjs.c.JSContext,
    err_code: ErrorCode,
    message: []const u8,
    err: ?anyerror,
    diag: ?*const Diagnostic,
    trace: ?*const std.builtin.StackTrace,
) qjs.c.JSValue {
    const allocator = std.heap.page_allocator;
    const native_stack = if (config.config.debug.native_stack_trace and err != null)
        formatNativeStackAlloc(err.?, trace, allocator) catch null
    else
        null;
    defer if (native_stack) |owned| allocator.free(owned);

    const detail_owned = if (diag) |diagnostic|
        if (!diagnostic.isEmpty())
            null
        else if (err) |native_err|
            std.fmt.allocPrint(allocator, "{s}: {s}", .{ message, @errorName(native_err) }) catch null
        else
            null
    else if (err) |native_err|
        std.fmt.allocPrint(allocator, "{s}: {s}", .{ message, @errorName(native_err) }) catch null
    else
        null;
    defer if (detail_owned) |owned| allocator.free(owned);

    const final_message = if (diag) |diagnostic|
        if (!diagnostic.isEmpty()) diagnostic.slice() else detail_owned orelse message
    else
        detail_owned orelse message;

    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const ctor = qjs.getProperty(ctx, global, "RuntimeError");
    defer qjs.freeValue(ctx, ctor);
    if (!qjs.isFunction(ctx, ctor)) return qjs.c.JS_ThrowInternalError(ctx, "RuntimeError unavailable");

    var args = [_]qjs.c.JSValue{
        qjs.createString(ctx, @tagName(err_code)),
        qjs.createString(ctx, final_message),
    };
    defer qjs.freeValue(ctx, args[0]);
    defer qjs.freeValue(ctx, args[1]);

    const err_obj = qjs.c.JS_CallConstructor(ctx, ctor, args.len, @ptrCast(&args));
    if (qjs.isException(err_obj)) return err_obj;
    errdefer qjs.freeValue(ctx, err_obj);

    if (native_stack) |text| {
        const stack_value = qjs.createString(ctx, text);
        if (qjs.isException(stack_value)) return stack_value;
        qjs.setProperty(ctx, err_obj, "nativeStack", stack_value) catch return qjs.exceptionValue();
    }
    return qjs.c.JS_Throw(ctx, err_obj);
}

pub fn jsNativeError(
    ctx: ?*qjs.c.JSContext,
    err_code: ErrorCode,
    message: []const u8,
    err: anyerror,
    diag: ?*const Diagnostic,
) qjs.c.JSValue {
    return jsError(ctx, err_code, message, err, diag, @errorReturnTrace());
}

pub fn jsClassifiedNativeError(
    ctx: ?*qjs.c.JSContext,
    message: []const u8,
    err: anyerror,
    diag: ?*const Diagnostic,
) qjs.c.JSValue {
    return jsNativeError(ctx, classifyNativeError(err), message, err, diag);
}

pub fn jsNativeErrorWithDetail(
    ctx: ?*qjs.c.JSContext,
    err_code: ErrorCode,
    message: []const u8,
    detail: ?[]const u8,
    err: anyerror,
    diag: ?*const Diagnostic,
) qjs.c.JSValue {
    if (detail) |text| {
        const allocator = std.heap.page_allocator;
        const full = std.fmt.allocPrint(allocator, "{s} ({s})", .{ message, text }) catch message;
        defer if (full.ptr != message.ptr) allocator.free(full);
        return jsNativeError(ctx, err_code, full, err, diag);
    }
    return jsNativeError(ctx, err_code, message, err, diag);
}

pub fn jsClassifiedNativeErrorWithDetail(
    ctx: ?*qjs.c.JSContext,
    message: []const u8,
    detail: ?[]const u8,
    err: anyerror,
    diag: ?*const Diagnostic,
) qjs.c.JSValue {
    return jsNativeErrorWithDetail(ctx, classifyNativeError(err), message, detail, err, diag);
}

pub fn classifyNativeError(err: anyerror) ErrorCode {
    return switch (err) {
        error.InvalidArgument,
        error.IndexOutOfBounds,
        error.UnsupportedFeature,
        error.SyntaxError,
        => .invalid_arg,

        error.ShapeMismatch,
        error.IncompatibleShapes,
        error.SizeMismatch,
        => .shape_mismatch,

        error.UnsupportedShape,
        => .invalid_shape,

        error.DTypeMismatch,
        error.TypeMismatch,
        error.UnsupportedDType,
        => .invalid_dtype,

        error.OutOfMemory => .out_of_memory,

        error.FileNotFound,
        error.AccessDenied,
        error.SymbolNotFound,
        error.OpenLibraryFailed,
        => .io_error,

        error.Cancelled => .cancelled,
        error.InvalidState => .invalid_state,

        else => .internal,
    };
}

pub fn formatNativeStackAlloc(err: anyerror, trace: ?*const std.builtin.StackTrace, allocator: std.mem.Allocator) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, @errorName(err));
    if (trace) |stack_trace| {
        try out.appendSlice(allocator, "\n");
        if (@hasDecl(std.builtin.StackTrace, "format")) {
            try out.print(allocator, "{f}", .{stack_trace.*});
        } else {
            const frame_count = @min(stack_trace.index, stack_trace.instruction_addresses.len);
            try out.print(allocator, "native stack trace captured ({d} frames)", .{frame_count});
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn formatCurrentNativeStackAlloc(start_addr: ?usize, allocator: std.mem.Allocator) !?[]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const debug_info = std.debug.getSelfDebugInfo() catch |err| {
        return std.fmt.allocPrint(allocator, "Unable to capture native stack: {s}", .{@errorName(err)});
    };
    std.debug.writeCurrentStackTrace(&aw.writer, debug_info, .no_color, start_addr) catch |err| {
        return std.fmt.allocPrint(allocator, "Unable to capture native stack: {s}", .{@errorName(err)});
    };
    return aw.toOwnedSlice();
}

pub fn warn(warn_code: ErrorCode, message: []const u8) void {
    std.debug.print("[hao] warning [{s}]: {s}\n", .{ @tagName(warn_code), message });
}

test "Diagnostic empty on init" {
    const d: Diagnostic = .{};
    try std.testing.expect(d.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), d.message_len);
}

test "Diagnostic.set basic" {
    var d: Diagnostic = .{};
    d.set("shape {d} != {d}", .{ 3, 4 });
    try std.testing.expect(!d.isEmpty());
    try std.testing.expectEqualStrings("shape 3 != 4", d.slice());
}

test "Diagnostic.set truncation marker on overflow" {
    var d: Diagnostic = .{};
    var long_buf: [1100]u8 = undefined;
    @memset(&long_buf, 'x');
    d.set("{s}", .{long_buf[0..]});
    try std.testing.expectEqual(Diagnostic.max_len, d.message_len);
    try std.testing.expect(std.mem.endsWith(u8, d.slice(), Diagnostic.truncation_marker));
}

test "DiagnosticScope restores previous diagnostic" {
    var first: Diagnostic = .{};
    var second: Diagnostic = .{};

    const previous = setCurrentDiagnostic(null);
    defer _ = setCurrentDiagnostic(previous);

    var outer = DiagnosticScope.enter(&first);
    defer outer.exit();
    try std.testing.expect(currentDiagnostic() == &first);

    {
        var inner = DiagnosticScope.enter(&second);
        defer inner.exit();
        try std.testing.expect(currentDiagnostic() == &second);
    }

    try std.testing.expect(currentDiagnostic() == &first);
}

test "nativeErrorWithCurrent writes into active diagnostic" {
    var diag: Diagnostic = .{};
    const previous = setCurrentDiagnostic(null);
    defer _ = setCurrentDiagnostic(previous);

    var scope = DiagnosticScope.enter(&diag);
    defer scope.exit();

    const err = nativeErrorWithCurrent(error.ShapeMismatch, "shape mismatch: {d} vs {d}", .{ 2, 3 });
    try std.testing.expectEqual(error.ShapeMismatch, err);
    try std.testing.expectEqualStrings("shape mismatch: 2 vs 3", diag.slice());
}

test "classify runtime errors" {
    try std.testing.expectEqual(ErrorCode.invalid_arg, classifyNativeError(error.InvalidArgument));
    try std.testing.expectEqual(ErrorCode.invalid_arg, classifyNativeError(error.UnsupportedFeature));
    try std.testing.expectEqual(ErrorCode.out_of_memory, classifyNativeError(error.OutOfMemory));
    try std.testing.expectEqual(ErrorCode.io_error, classifyNativeError(error.SymbolNotFound));
}
