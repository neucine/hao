import { install_native } from .global.console_native;

pub fn install(runtime_handle: c_size_t): i32 {
    return install_native(runtime_handle) as i32;
}
