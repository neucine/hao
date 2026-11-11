import { eval_source, install_stack_capture } from .bridge.qjs;

pub fn install_runtime_error(context: *c_void): c_int {
    const source = "if (typeof globalThis.RuntimeError !== 'function') {globalThis.RuntimeError = class RuntimeError extends Error {constructor(code, message) { super(message); this.name = 'RuntimeError'; this.code = code; }}; }";
    const bytes = source.bytes();
    if eval_source(context, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) != 0 { return -1; }
    install_stack_capture(context);
    return 0;
}
