const std = @import("std");
const uv = @import("uv.zig").c;

threadlocal var current_loop: ?*Loop = null;

pub const TimerFireFn = *const fn (?*anyopaque) void;
pub const TimerCloseFn = *const fn (?*anyopaque) void;

pub const Loop = struct {
    loop: *uv.uv_loop_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Loop {
        const loop_ptr = try allocator.create(uv.uv_loop_t);
        errdefer allocator.destroy(loop_ptr);

        const self = Loop{
            .loop = loop_ptr,
            .allocator = allocator,
        };
        if (uv.uv_loop_init(self.loop) != 0) return error.LibuvLoopInitFailed;
        return self;
    }

    pub fn deinit(self: *Loop) void {
        while (uv.uv_loop_close(self.loop) == uv.UV_EBUSY) {
            _ = uv.uv_run(self.loop, uv.UV_RUN_DEFAULT);
        }
        self.allocator.destroy(self.loop);
    }

    pub fn runOnce(self: *Loop) !bool {
        const rc = uv.uv_run(self.loop, uv.UV_RUN_ONCE);
        if (rc < 0) return error.LibuvRunFailed;
        return rc != 0;
    }

    // Report whether a turn was serviced, even if its last handle closed.
    // The caller must drain JS jobs between turns for persistent listeners.
    pub fn runTurn(self: *Loop) !bool {
        if (uv.uv_loop_alive(self.loop) == 0) return false;
        _ = try self.runOnce();
        return true;
    }

    pub fn runUntilIdle(self: *Loop) !bool {
        if (uv.uv_loop_alive(self.loop) == 0) return false;
        const rc = uv.uv_run(self.loop, uv.UV_RUN_DEFAULT);
        if (rc < 0) return error.LibuvRunFailed;
        return true;
    }

    pub fn runNowait(self: *Loop) !bool {
        if (uv.uv_loop_alive(self.loop) == 0) return false;
        const rc = uv.uv_run(self.loop, uv.UV_RUN_NOWAIT);
        if (rc < 0) return error.LibuvRunFailed;
        return rc != 0;
    }

    pub fn startTimer(
        self: *Loop,
        handle: *TimerHandle,
        delay_ms: u64,
        userdata: ?*anyopaque,
        on_fire: TimerFireFn,
        on_close: TimerCloseFn,
    ) !void {
        handle.* = .{
            .handle = undefined,
            .closed = false,
            .userdata = userdata,
            .on_fire = on_fire,
            .on_close = on_close,
        };

        if (uv.uv_timer_init(self.loop, &handle.handle) != 0) return error.LibuvTimerInitFailed;
        handle.handle.data = handle;

        if (uv.uv_timer_start(&handle.handle, onLibuvTimerFire, if (delay_ms == 0) 1 else delay_ms, 0) != 0) {
            _ = uv.uv_close(@ptrCast(&handle.handle), onLibuvTimerClosed);
            return error.LibuvTimerStartFailed;
        }
    }

    pub fn cancelTimer(self: *Loop, handle: *TimerHandle) void {
        _ = self;
        if (handle.closed) return;
        handle.closed = true;
        _ = uv.uv_timer_stop(&handle.handle);
        uv.uv_close(@ptrCast(&handle.handle), onLibuvTimerClosed);
    }

    pub fn scheduleOneShot(self: *Loop, delay_ms: u64, fired: *bool) !void {
        const op = try self.allocator.create(TimerOp);
        errdefer self.allocator.destroy(op);

        op.* = .{
            .allocator = self.allocator,
            .fired = fired,
            .handle = undefined,
        };
        try self.startTimer(&op.handle, delay_ms, op, onOneShotTimerFire, onOneShotTimerClosed);
    }
};

pub fn attachCurrent(loop: *Loop) void {
    current_loop = loop;
}

pub fn detachCurrent() void {
    current_loop = null;
}

pub fn current() ?*Loop {
    return current_loop;
}

const TimerOp = struct {
    allocator: std.mem.Allocator,
    fired: *bool,
    handle: TimerHandle,
};

pub const TimerHandle = struct {
    handle: uv.uv_timer_t,
    userdata: ?*anyopaque,
    on_fire: TimerFireFn,
    on_close: TimerCloseFn,
    closed: bool,
};

const LibuvTimerState = TimerHandle;

fn onOneShotTimerFire(userdata: ?*anyopaque) void {
    const op: *TimerOp = @ptrCast(@alignCast(userdata orelse return));
    op.fired.* = true;
}

fn onOneShotTimerClosed(userdata: ?*anyopaque) void {
    const op: *TimerOp = @ptrCast(@alignCast(userdata orelse return));
    op.allocator.destroy(op);
}

fn onLibuvTimerFire(handle: ?*uv.uv_timer_t) callconv(.c) void {
    const timer = handle orelse return;
    const state: *LibuvTimerState = @ptrCast(@alignCast(timer.data));
    state.on_fire(state.userdata);
    if (!state.closed) {
        state.closed = true;
        _ = uv.uv_timer_stop(&state.handle);
        uv.uv_close(@ptrCast(&state.handle), onLibuvTimerClosed);
    }
}

fn onLibuvTimerClosed(handle: ?*uv.uv_handle_t) callconv(.c) void {
    const uv_handle = handle orelse return;
    const state: *LibuvTimerState = @ptrCast(@alignCast(uv_handle.data));
    state.on_close(state.userdata);
}

test "libuv loop supports one-shot timer" {
    var loop = try Loop.init(std.testing.allocator);
    defer loop.deinit();

    var fired = false;
    try loop.scheduleOneShot(1, &fired);
    _ = try loop.runUntilIdle();

    try std.testing.expect(fired);
}
