import { install_timer_native as install_native } from .bridge.qjs;

pub fn install(runtime_handle: c_size_t): i32 {
    return install_native(runtime_handle) as i32;
}
