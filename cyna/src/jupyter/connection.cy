import { read_file } from std.fs;
import { Value, parse as parse_json } from std.json;
import { within_limit } from .fs_limit;

pub struct Connection {
    pub transport: string;
    pub ip: string;
    pub shell_port: u16;
    pub control_port: u16;
    pub iopub_port: u16;
    pub stdin_port: u16;
    pub hb_port: u16;
    pub key: string;
    pub signature_scheme: string;

    pub fn endpoint(self: &const Connection, port: u16): string {
        return $"{self.transport}://{self.ip}:{port}";
    }
}

fn string_field(value: &const Value, key: string): ?string {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .string(text) => { return text.clone(); }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return none;
}

fn port_text(value: string): ?u16 {
    const bytes = value.bytes();
    if bytes.len() == 0 or bytes.len() > 5 {
        return none;
    }
    var port: u32 = 0;
    for byte in bytes {
        if byte < 48 or byte > 57 {
            return none;
        }
        port = port * 10 + (byte - 48) as u32;
        if port > 65535 {
            return none;
        }
    }
    return port as u16;
}

fn port_field(value: &const Value, key: string): ?u16 {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .number(number) => { return port_text(number.spelling); }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return none;
}

fn or_default(value: ?string, fallback: string): string {
    if value is present {
        return present;
    }
    return fallback;
}

pub fn parse(path: string): ?Connection {
    const bytes = path.bytes();
    if within_limit(bytes.ptr as! *const c_uchar, bytes.len() as c_size_t, 64 * 1024) == 0 {
        return none;
    }
    const source = read_file(path) catch (code) { return none; };
    if source.len() > 64 * 1024 { return none; }
    const value = parse_json(source) catch (code) { return none; };
    const shell_port = port_field(&value, "shell_port");
    const control_port = port_field(&value, "control_port");
    const iopub_port = port_field(&value, "iopub_port");
    const stdin_port = port_field(&value, "stdin_port");
    const hb_port = port_field(&value, "hb_port");
    if shell_port is none { return none; }
    if control_port is none { return none; }
    if iopub_port is none { return none; }
    if stdin_port is none { return none; }
    if hb_port is none { return none; }
    return Connection {
        transport: or_default(string_field(&value, "transport"), "tcp"),
        ip: or_default(string_field(&value, "ip"), "127.0.0.1"),
        shell_port: shell_port,
        control_port: control_port,
        iopub_port: iopub_port,
        stdin_port: stdin_port,
        hb_port: hb_port,
        key: or_default(string_field(&value, "key"), ""),
        signature_scheme: or_default(string_field(&value, "signature_scheme"), "hmac-sha256"),
    };
}
