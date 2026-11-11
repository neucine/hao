import { write_fd } from .bridge.host;

pub fn write_stderr(message: string): void {
    const bytes = message.bytes();
    if write_fd(2, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) < 0 { return; }
}
