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

