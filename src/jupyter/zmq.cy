import { wire_open as native_open, wire_close as native_close,
    wire_poll as native_poll, wire_field_length as native_field_length,
    wire_field as native_field, wire_send as native_send } from .bridge.jupyter;
import { Connection } from .jupyter.connection;
import { copy_bytes } from .c_bytes;

pub fn open(connection: &const Connection): ?c_size_t {
    const transport = connection.transport.bytes();
    const ip = connection.ip.bytes();
    const key = connection.key.bytes();
    const handle = native_open(transport.ptr as! *const c_uchar, transport.len() as c_size_t,
        ip.ptr as! *const c_uchar, ip.len() as c_size_t,
        connection.shell_port as c_ushort, connection.control_port as c_ushort,
        connection.iopub_port as c_ushort, connection.stdin_port as c_ushort,
        connection.hb_port as c_ushort,
        key.ptr as! *const c_uchar, key.len() as c_size_t);
    if handle == 0 { return none; }
    return handle;
}

pub fn close(handle: c_size_t): void { native_close(handle); }
pub fn poll(handle: c_size_t, timeout_ms: i32): i32 {
    return native_poll(handle, timeout_ms as c_int) as i32;
}

pub fn field(handle: c_size_t, code: i32): ?string {
    const length = native_field_length(handle, code as c_int);
    if native_field(handle, code as c_int) is pointer {
        const bytes = copy_bytes(pointer, length as usize);
        return string.from(bytes[..]);
    }
    return none;
}

pub fn send(handle: c_size_t, channel: i32, kind: string, content: string): i32 {
    const kind_bytes = kind.bytes();
    const content_bytes = content.bytes();
    return native_send(handle, channel as c_int,
        kind_bytes.ptr as! *const c_uchar, kind_bytes.len() as c_size_t,
        content_bytes.ptr as! *const c_uchar, content_bytes.len() as c_size_t) as i32;
}
