pub extern c("hao_global_install_console") fn install_native(handle: c_size_t): c_int;
pub extern c("hao_test_print_load") fn test_print_load(index: c_size_t, total: c_size_t, path: *const c_uchar, length: c_size_t): void;
