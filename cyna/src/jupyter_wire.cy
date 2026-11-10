import { Connection } from .jupyter_connection;
import { copy_bytes } from .c_bytes;

extern c("hao_jupyter_wire_open") fn wire_open(transport: *const c_uchar, transport_len: c_size_t,
    ip: *const c_uchar, ip_len: c_size_t, shell_port: c_ushort, control_port: c_ushort,
    iopub_port: c_ushort, stdin_port: c_ushort, hb_port: c_ushort,
    key: *const c_uchar, key_len: c_size_t): c_size_t;
extern c("hao_jupyter_wire_close") fn wire_close(handle: c_size_t): void;
extern c("hao_jupyter_wire_poll") fn wire_poll(handle: c_size_t, timeout_ms: c_int): c_int;
extern c("hao_jupyter_wire_field_length") fn wire_field_length(handle: c_size_t, field: c_int): c_size_t;
extern c("hao_jupyter_wire_field_view") fn wire_field(handle: c_size_t, field: c_int): ?*const c_uchar;
extern c("hao_jupyter_wire_send") fn wire_send(handle: c_size_t, channel: c_int,
    kind: *const c_uchar, kind_len: c_size_t, content: *const c_uchar, content_len: c_size_t): c_int;

pub struct Wire {
    handle: c_size_t;

    pub fn open(connection: &const Connection): ?Wire {
        const transport = connection.transport.bytes();
        const ip = connection.ip.bytes();
        const key = connection.key.bytes();
        const handle = wire_open(transport.ptr as! *const c_uchar, transport.len() as c_size_t,
            ip.ptr as! *const c_uchar, ip.len() as c_size_t,
            connection.shell_port as c_ushort, connection.control_port as c_ushort, connection.iopub_port as c_ushort,
            connection.stdin_port as c_ushort, connection.hb_port as c_ushort,
            key.ptr as! *const c_uchar, key.len() as c_size_t);
        if handle == 0 { return none; }
        return Wire { handle: handle };
    }

    pub fn deinit(self: Wire): void { wire_close(self.handle); }
    pub fn poll(self: &const Wire, timeout_ms: i32): i32 { return wire_poll(self.handle, timeout_ms as c_int) as i32; }

    fn field(self: &const Wire, code: i32): ?string {
        const length = wire_field_length(self.handle, code as c_int);
        if wire_field(self.handle, code as c_int) is pointer {
            const bytes = copy_bytes(pointer, length as usize);
            return string.from(bytes[..]);
        }
        return none;
    }

    pub fn header(self: &const Wire): ?string { return self.field(1); }
    pub fn content(self: &const Wire): ?string { return self.field(2); }

    pub fn send(self: &const Wire, channel: i32, kind: string, content: string): i32 {
        const kind_bytes = kind.bytes();
        const content_bytes = content.bytes();
        return wire_send(self.handle, channel as c_int,
            kind_bytes.ptr as! *const c_uchar, kind_bytes.len() as c_size_t,
            content_bytes.ptr as! *const c_uchar, content_bytes.len() as c_size_t) as i32;
    }
}
