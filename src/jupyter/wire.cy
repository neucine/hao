import { wire_open, wire_close, wire_poll, wire_field_length, wire_field, wire_send } from .jupyter.zmq;
import { Connection } from .jupyter.connection;
import { copy_bytes } from .c_bytes;


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
