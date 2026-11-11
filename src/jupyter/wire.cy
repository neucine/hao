import { open, close, poll, field, send } from .jupyter.zmq;
import { Connection } from .jupyter.connection;


pub struct Wire {
    handle: c_size_t;

    pub fn open(connection: &const Connection): ?Wire {
        if open(connection) is handle { return Wire { handle: handle }; }
        return none;
    }

    pub fn deinit(self: Wire): void { close(self.handle); }
    pub fn poll(self: &const Wire, timeout_ms: i32): i32 { return poll(self.handle, timeout_ms); }
    pub fn header(self: &const Wire): ?string { return field(self.handle, 1); }
    pub fn content(self: &const Wire): ?string { return field(self.handle, 2); }

    pub fn send(self: &const Wire, channel: i32, kind: string, content: string): i32 {
        return send(self.handle, channel, kind, content);
    }
}
