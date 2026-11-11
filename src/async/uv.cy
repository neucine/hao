// libuv owns its loop and callback handles in the C adapter. Cyna drives one
// turn at a time so QuickJS jobs are drained between native callbacks.
extern c("hao_runtime_run_turn") fn runtime_run_turn(handle: c_size_t): c_int;

pub fn run_turn(runtime_handle: c_size_t): i32 {
    return runtime_run_turn(runtime_handle) as i32;
}
