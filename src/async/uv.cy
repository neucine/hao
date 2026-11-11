import { runtime_run_turn } from .bridge;
// libuv owns the opaque loop and callback handles. Cyna drives one turn at a
// time so QuickJS jobs are drained between native callbacks.

extern c("uv_loop_size") fn loop_size(): c_size_t;
extern c("uv_loop_init") fn loop_init(loop: *c_void): c_int;
extern c("uv_loop_close") fn loop_close(loop: *c_void): c_int;
extern c("uv_loop_alive") fn loop_alive(loop: *c_void): c_int;
extern c("uv_run") fn uv_run(loop: *c_void, mode: c_int): c_int;
extern c("hao_alloc") fn runtime_alloc(size: c_size_t): *c_void;
extern c("hao_free") fn free(pointer: *c_void): void;

export c("hao_async_uv_new") fn new_loop(): *c_void {
    const loop = runtime_alloc(loop_size());
    if loop == (0 as! *c_void) { return loop; }
    if loop_init(loop) != 0 {
        free(loop);
        return 0 as! *c_void;
    }
    return loop;
}

export c("hao_async_uv_free") fn free_loop(loop: *c_void): void {
    if loop == (0 as! *c_void) { return; }
    while loop_close(loop) == -16 {
        const run_result = uv_run(loop, 0);
    }
    free(loop);
}

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
