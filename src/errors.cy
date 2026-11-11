extern c("hao_error_eval") fn eval_source(context: *c_void, source: *const c_uchar, length: c_size_t): c_int;
extern c("hao_error_install_stack_capture") fn install_stack_capture(context: *c_void): void;

export c("hao_install_runtime_error") fn install_runtime_error(context: *c_void): c_int {
    const source = "if (typeof globalThis.RuntimeError !== 'function') {globalThis.RuntimeError = class RuntimeError extends Error {constructor(code, message) { super(message); this.name = 'RuntimeError'; this.code = code; }}; }";
    const bytes = source.bytes();
    if eval_source(context, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) != 0 { return -1; }
    install_stack_capture(context);
    return 0;
}
