import { runtime_run_turn } from .bridge.qjs;
import { allocate as runtime_alloc, free } from .runtime_allocator;
// libuv owns the opaque loop and callback handles. Cyna drives one turn at a
// time so QuickJS jobs are drained between native callbacks.

import { loop_size, loop_init, loop_close, loop_alive, uv_run } from .bridge.uv;

pub fn new_loop(): *c_void {
    const loop = runtime_alloc(loop_size());
    if loop == (0 as! *c_void) { return loop; }
    if loop_init(loop) != 0 {
        free(loop);
        return 0 as! *c_void;
    }
    return loop;
}

pub fn free_loop(loop: *c_void): void {
    if loop == (0 as! *c_void) { return; }
    while loop_close(loop) == -16 {
        const run_result = uv_run(loop, 0);
    }
    free(loop);
}

pub fn run_once(loop: *c_void): c_int {
    if loop == (0 as! *c_void) { return 0; }
    if loop_alive(loop) == 0 { return 0; }
    if uv_run(loop, 1) < 0 { return -1; }
    return 1;
}

pub fn run_nowait(loop: *c_void): c_int {
    if loop == (0 as! *c_void) { return 0; }
    if loop_alive(loop) == 0 { return 0; }
    return uv_run(loop, 2);
}

pub fn run_turn(runtime_handle: c_size_t): i32 {
    return runtime_run_turn(runtime_handle) as i32;
}
