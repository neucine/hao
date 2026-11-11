pub extern c("hao_fs_read_limited") fn read_limited(path: *const c_uchar, length: c_size_t, output: *c_uchar, capacity: c_size_t): c_int;
pub extern c("hao_fs_script_read_error") fn script_read_error(path: *const c_uchar, length: c_size_t, limit: c_size_t): c_int;
