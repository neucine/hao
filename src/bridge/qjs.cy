pub extern c("hao_runtime_new") fn runtime_new(stack_size: c_size_t, gc_threshold: c_size_t,
    thread_pool_size: c_size_t, trace_records: c_size_t, console_enabled: c_int): c_size_t;
pub extern c("hao_runtime_free") fn runtime_free(handle: c_size_t): void;
pub extern c("hao_runtime_start_tests") fn runtime_start_tests(handle: c_size_t, grep: *const c_uchar, grep_len: c_size_t): c_int;
pub extern c("hao_runtime_test_failures") fn runtime_test_failures(handle: c_size_t): c_int;
pub extern c("hao_runtime_set_test_file_counts") fn runtime_set_test_file_counts(handle: c_size_t, loaded: c_size_t, failed: c_size_t, total: c_size_t): c_int;
pub extern c("hao_runtime_set_executable") fn runtime_set_executable(handle: c_size_t, path: *const c_uchar, path_len: c_size_t): c_int;
pub extern c("hao_runtime_eval_cell") fn runtime_eval_cell(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): ?*const c_uchar;
pub extern c("hao_runtime_free_text") fn runtime_free_text(text: *const c_uchar): void;
pub extern c("hao_runtime_drain_test") fn runtime_drain_test(handle: c_size_t, path: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_runtime_set_telemetry_console") fn runtime_set_telemetry_console(handle: c_size_t, enabled: c_int, port: c_ushort): void;
pub extern c("hao_runtime_set_native_stack_trace") fn runtime_set_native_stack_trace(handle: c_size_t, enabled: c_int): void;
pub extern c("hao_runtime_eval") fn runtime_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
pub extern c("hao_runtime_eval_test") fn runtime_eval_test(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
pub extern c("hao_runtime_drain") fn runtime_drain(handle: c_size_t): c_int;
pub extern c("hao_runtime_run_turn") fn runtime_run_turn(handle: c_size_t): c_int;
pub extern c("hao_embed_bytes_valid") fn bytes_valid(pointer: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_embed_clear_error") fn clear_error(handle: c_size_t): void;
pub extern c("hao_embed_invalid_buffer") fn invalid_buffer(handle: c_size_t): void;
pub extern c("hao_embed_set_error") fn set_error(handle: c_size_t, message: *const c_uchar, length: c_size_t): void;

pub extern c("hao_runtime_register") fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int;

pub extern c("hao_global_install_console") fn install_console_native(handle: c_size_t): c_int;
pub extern c("hao_test_print_load") fn test_print_load(index: c_size_t, total: c_size_t, path: *const c_uchar, length: c_size_t): void;
pub extern c("hao_global_install_timer") fn install_timer_native(handle: c_size_t): c_int;
pub extern c("hao_error_eval") fn eval_source(context: *c_void, source: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_error_install_stack_capture") fn install_stack_capture(context: *c_void): void;
