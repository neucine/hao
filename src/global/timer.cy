extern c("hao_global_install_timer") fn install_native(handle: c_size_t): c_int;

pub fn install(runtime_handle: c_size_t): i32 {
    return install_native(runtime_handle) as i32;
}
