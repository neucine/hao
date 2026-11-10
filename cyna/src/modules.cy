extern c("hao_runtime_eval") fn runtime_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
extern c("hao_runtime_register") fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int;

pub fn eval(handle: c_size_t, source: string, filename: string): i32 {
    const source_bytes = source.bytes();
    const name_bytes = filename.bytes();
    return runtime_eval(handle, source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t,
        name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t) as i32;
}

pub fn register_source(handle: c_size_t, name: string, source: string): i32 {
    const name_bytes = name.bytes();
    const source_bytes = source.bytes();
    return runtime_register(handle, name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t,
        source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t) as i32;
}
