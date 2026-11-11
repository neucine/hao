extern c("write") fn write_fd(fd: c_int, bytes: *const c_uchar, count: c_size_t): c_long;

pub fn write_stderr(message: string): void {
    const bytes = message.bytes();
    if write_fd(2, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) < 0 { return; }
}
