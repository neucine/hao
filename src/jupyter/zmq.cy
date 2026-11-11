import { wire_open as native_open, wire_close as native_close,
    wire_poll as native_poll, wire_field_length as native_field_length,
    wire_field as native_field, wire_send as native_send } from .bridge.jupyter;

pub fn wire_open(transport: *const c_uchar, transport_len: c_size_t,
    ip: *const c_uchar, ip_len: c_size_t, shell_port: c_ushort, control_port: c_ushort,
    iopub_port: c_ushort, stdin_port: c_ushort, hb_port: c_ushort,
    key: *const c_uchar, key_len: c_size_t): c_size_t {
    return native_open(transport, transport_len, ip, ip_len, shell_port, control_port,
        iopub_port, stdin_port, hb_port, key, key_len);
}
pub fn wire_close(handle: c_size_t): void { native_close(handle); }
pub fn wire_poll(handle: c_size_t, timeout_ms: c_int): c_int { return native_poll(handle, timeout_ms); }
pub fn wire_field_length(handle: c_size_t, field: c_int): c_size_t {
    return native_field_length(handle, field);
}
pub fn wire_field(handle: c_size_t, field: c_int): ?*const c_uchar {
    return native_field(handle, field);
}
pub fn wire_send(handle: c_size_t, channel: c_int,
    kind: *const c_uchar, kind_len: c_size_t, content: *const c_uchar, content_len: c_size_t): c_int {
    return native_send(handle, channel, kind, kind_len, content, content_len);
}
