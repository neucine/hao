pub extern c("hao_runtime_register") fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int;
