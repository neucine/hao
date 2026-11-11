import { runtime_eval, runtime_eval_test } from .bridge;
import { runtime_register } from .module_ffi;

pub fn eval(handle: c_size_t, source: string, filename: string): i32 {
    const source_bytes = source.bytes();
    const name_bytes = filename.bytes();
    return runtime_eval(handle, source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t,
        name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t) as i32;
}

pub fn eval_test(handle: c_size_t, source: string, filename: string): i32 {
    const source_bytes = source.bytes();
    const name_bytes = filename.bytes();
    return runtime_eval_test(handle, source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t,
        name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t) as i32;
}

pub fn register_source(handle: c_size_t, name: string, source: string): i32 {
    const name_bytes = name.bytes();
    const source_bytes = source.bytes();
    return runtime_register(handle, name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t,
        source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t) as i32;
}
