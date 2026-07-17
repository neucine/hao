const std = @import("std");
const qjs = @import("../qjs.zig");
const async_loop = @import("../async/loop.zig");

var next_timer_id: u32 = 1;
var timers: std.AutoHashMapUnmanaged(u32, *TimerOp) = .empty;

const TimerOp = struct {
    id: u32,
    ctx: ?*qjs.c.JSContext,
    callback: qjs.c.JSValue,
    handle: async_loop.TimerHandle,
    allocator: std.mem.Allocator,
    closed: bool = false,

    fn cancel(self: *TimerOp, loop: *async_loop.Loop) void {
        if (self.closed) return;
        self.closed = true;
        loop.cancelTimer(&self.handle);
    }
};

pub fn register(ctx: ?*qjs.c.JSContext) !void {
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    try qjs.setProperty(ctx, global, "setTimeout", qjs.c.JS_NewCFunction(ctx, jsSetTimeout, "setTimeout", 2));
    try qjs.setProperty(ctx, global, "clearTimeout", qjs.c.JS_NewCFunction(ctx, jsClearTimeout, "clearTimeout", 1));
}

pub fn cleanup(allocator: std.mem.Allocator) void {
    var it = timers.valueIterator();
    while (it.next()) |op_ptr| {
        const op = op_ptr.*;
        qjs.freeValue(op.ctx, op.callback);
        allocator.destroy(op);
    }
    timers.deinit(allocator);
    timers = .empty;
    next_timer_id = 1;
}

fn jsException(_: ?*qjs.c.JSContext) qjs.c.JSValue {
    return qjs.exceptionValue();
}

fn jsSetTimeout(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const loop = async_loop.current() orelse return jsException(ctx);
    if (argc < 1 or !qjs.isFunction(ctx, argv[0])) return jsException(ctx);

    var delay_ms: i64 = 0;
    if (argc >= 2) {
        if (qjs.c.JS_ToInt64(ctx, &delay_ms, argv[1]) < 0) return jsException(ctx);
        if (delay_ms < 0) delay_ms = 0;
    }

    const id = next_timer_id;
    next_timer_id +%= 1;
    if (next_timer_id == 0) next_timer_id = 1;

    const op = loop.allocator.create(TimerOp) catch return jsException(ctx);
    errdefer loop.allocator.destroy(op);
    op.* = .{
        .id = id,
        .ctx = ctx,
        .callback = qjs.dupValue(ctx, argv[0]),
        .handle = undefined,
        .allocator = loop.allocator,
    };
    errdefer qjs.freeValue(ctx, op.callback);

    timers.put(loop.allocator, id, op) catch return jsException(ctx);
    errdefer _ = timers.fetchRemove(id);

    loop.startTimer(&op.handle, @intCast(delay_ms), op, onFire, onClosed) catch {
        _ = timers.fetchRemove(id);
        qjs.freeValue(ctx, op.callback);
        loop.allocator.destroy(op);
        return jsException(ctx);
    };

    return qjs.c.JS_NewInt32(ctx, @intCast(id));
}

fn jsClearTimeout(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 1) return qjs.undefinedValue(ctx);

    var id: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &id, argv[0]) < 0 or id <= 0) {
        return qjs.undefinedValue(ctx);
    }

    const loop = async_loop.current() orelse return qjs.undefinedValue(ctx);
    if (timers.fetchRemove(@intCast(id))) |entry| {
        entry.value.cancel(loop);
    }
    return qjs.undefinedValue(ctx);
}

fn onFire(userdata: ?*anyopaque) void {
    const op: *TimerOp = @ptrCast(@alignCast(userdata orelse return));
    _ = timers.fetchRemove(op.id);

    const result = qjs.call(op.ctx, op.callback, qjs.undefinedValue(op.ctx), &.{});
    if (qjs.isException(result)) {
        const exception = qjs.c.JS_GetException(op.ctx);
        qjs.recordUnhandledException(op.ctx, exception);
        qjs.freeValue(op.ctx, exception);
    }
    qjs.freeValue(op.ctx, result);
    op.closed = true;
}

fn onClosed(userdata: ?*anyopaque) void {
    const op: *TimerOp = @ptrCast(@alignCast(userdata orelse return));
    qjs.freeValue(op.ctx, op.callback);
    op.allocator.destroy(op);
}

test "timer globals install" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    try register(runtime.ctx);

    const value = qjs.eval(
        runtime.ctx,
        "typeof setTimeout === 'function' && typeof clearTimeout === 'function'",
        "<timer-qjs>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(runtime.ctx, value));
}
