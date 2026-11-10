extern c("hao_runtime_new") fn runtime_new(): c_size_t;
extern c("hao_runtime_free") fn runtime_free(handle: c_size_t): void;
extern c("hao_runtime_eval") fn runtime_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
extern c("hao_runtime_drain") fn runtime_drain(handle: c_size_t): c_int;
extern c("hao_runtime_register") fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int;

pub struct Runtime {
    handle: c_size_t;

    pub fn init(): ?Runtime {
        const handle = runtime_new();
        if handle == 0 {
            return none;
        }
        return Runtime {
            handle: handle
        };
    }

    pub fn deinit(self: Runtime): void {
        runtime_free(self.handle);
    }

    pub fn eval(self: &const Runtime, source: string, filename: string): i32 {
        const source_bytes = source.bytes();
        const name_bytes = filename.bytes();
        return runtime_eval(self.handle, source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t, name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t) as i32;
    }

    pub fn run_until_idle(self: &const Runtime): i32 {
        return runtime_drain(self.handle) as i32;
    }

    pub fn register_source_module(self: &const Runtime, name: string, source: string): i32 {
        const name_bytes = name.bytes();
        const source_bytes = source.bytes();
        return runtime_register(self.handle, name_bytes.ptr as! *const c_uchar, name_bytes.len() as c_size_t, source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t) as i32;
    }
}
