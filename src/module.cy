import { runtime_register as native_register } from .bridge.qjs;

pub fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t,
    source: *const c_uchar, source_len: c_size_t): c_int {
    return native_register(handle, name, name_len, source, source_len);
}
