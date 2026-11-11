// Native host APIs not supplied by the pinned Cyna standard library.

pub extern c("hao_alloc") fn allocate(size: c_size_t): *c_void;
pub extern c("hao_free") fn free(pointer: *c_void): void;

pub extern c("hao_process_execute") fn execute(program: *const c_uchar, program_len: c_size_t,
    args: *const c_uchar, args_len: c_size_t, args_count: c_size_t,
    cwd: *const c_uchar, cwd_len: c_size_t,
    stdout_output: *c_uchar, stderr_output: *c_uchar, capacity: c_size_t,
    result: *RunResult): c_int;

pub c struct RunResult {
    pub stdout_len: c_size_t;
    pub stderr_len: c_size_t;
    pub exit_code: c_int;
    pub has_exit_code: c_int;
    pub signal: c_int;
    pub has_signal: c_int;
}

pub extern c("hao_process_memory_native") fn native_snapshot(resident: *c_ullong, footprint: *c_ullong): void;

pub extern c("strlen") fn c_strlen(text: *const c_uchar): c_size_t;

pub extern c("write") fn write_fd(fd: c_int, bytes: *const c_uchar, count: c_size_t): c_long;
