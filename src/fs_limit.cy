pub extern c("hao_fs_read_limited") fn read_limited(path: *const c_uchar, length: c_size_t, output: *c_uchar, capacity: c_size_t): c_int;
pub extern c("hao_fs_script_read_error") fn script_read_error(path: *const c_uchar, length: c_size_t, limit: c_size_t): c_int;
pub extern c("hao_fs_read_alloc_limited") fn read_alloc_limited(path: *const c_uchar, length: c_size_t, limit: c_size_t): ?*c_uchar;
pub extern c("hao_fs_buffer_length") fn buffer_length(buffer: *const c_uchar): c_size_t;
pub extern c("hao_fs_free_buffer") fn free_buffer(buffer: *c_uchar): void;
pub extern c("hao_fs_path_exists") fn path_exists(path: *const c_uchar): c_int;
pub extern c("hao_fs_path_exists_len") fn path_exists_len(path: *const c_uchar, length: c_size_t): c_int;
