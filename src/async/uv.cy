import { runtime_run_turn } from .bridge;
// libuv owns its loop and callback handles in the C adapter. Cyna drives one
// turn at a time so QuickJS jobs are drained between native callbacks.

extern c("uv_loop_alive") fn loop_alive(loop: *c_void): c_int;
extern c("uv_run") fn uv_run(loop: *c_void, mode: c_int): c_int;

export c("hao_async_uv_run_once") fn run_once(loop: *c_void): c_int {
    if loop == (0 as! *c_void) { return 0; }
    if loop_alive(loop) == 0 { return 0; }
    if uv_run(loop, 1) < 0 { return -1; }
    return 1;
}

export c("hao_async_uv_run_nowait") fn run_nowait(loop: *c_void): c_int {
    if loop == (0 as! *c_void) { return 0; }
    if loop_alive(loop) == 0 { return 0; }
    return uv_run(loop, 2);
}

pub fn run_turn(runtime_handle: c_size_t): i32 {
    return runtime_run_turn(runtime_handle) as i32;
}
