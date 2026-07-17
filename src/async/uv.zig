pub const c = struct {
    pub const UV_EBUSY: c_int = -16;
    pub const UV_RUN_DEFAULT: c_int = 0;
    pub const UV_RUN_ONCE: c_int = 1;
    pub const UV_RUN_NOWAIT: c_int = 2;

    pub const uv_loop_t = extern struct {
        data: ?*anyopaque = null,
        _padding: [1064]u8 = undefined,
    };

    pub const uv_handle_t = extern struct {
        data: ?*anyopaque = null,
        _padding: [88]u8 = undefined,
    };

    pub const uv_timer_t = extern struct {
        data: ?*anyopaque = null,
        _padding: [144]u8 = undefined,
    };

    pub const uv_work_t = extern struct {
        data: ?*anyopaque = null,
        _padding: [120]u8 = undefined,
    };

    pub const uv_timer_cb = *const fn (?*uv_timer_t) callconv(.c) void;
    pub const uv_close_cb = *const fn (?*uv_handle_t) callconv(.c) void;
    pub const uv_work_cb = *const fn (?*uv_work_t) callconv(.c) void;
    pub const uv_after_work_cb = *const fn (?*uv_work_t, c_int) callconv(.c) void;

    pub extern "c" fn uv_loop_init(loop: *uv_loop_t) c_int;
    pub extern "c" fn uv_loop_close(loop: *uv_loop_t) c_int;
    pub extern "c" fn uv_loop_alive(loop: *uv_loop_t) c_int;
    pub extern "c" fn uv_run(loop: *uv_loop_t, mode: c_int) c_int;
    pub extern "c" fn uv_timer_init(loop: *uv_loop_t, handle: *uv_timer_t) c_int;
    pub extern "c" fn uv_timer_start(handle: *uv_timer_t, cb: uv_timer_cb, timeout: u64, repeat: u64) c_int;
    pub extern "c" fn uv_timer_stop(handle: *uv_timer_t) c_int;
    pub extern "c" fn uv_close(handle: *uv_handle_t, close_cb: uv_close_cb) void;
    pub extern "c" fn uv_queue_work(loop: *uv_loop_t, req: *uv_work_t, work_cb: uv_work_cb, after_work_cb: uv_after_work_cb) c_int;
};
