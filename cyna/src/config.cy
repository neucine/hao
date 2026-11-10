import { exists } from std.fs;
import { read_file_limited } from .fs;
import { env_get, env_set } from std.process;
import { parse_bool, parse_positive_usize, ConfigError } from std.config;

pub struct TelemetryConsoleSettings {
    pub enabled: bool;
    pub port: u16;
}

fn parse_port(raw: string): u16 ! ConfigError {
    const bytes = raw.bytes();
    if bytes.len() == 0 {
        throw ConfigError.invalid_value;
    }
    var all_zero = true;
    for byte in bytes {
        if byte != 48 {
            all_zero = false;
        }
    }
    if all_zero {
        return 0;
    }
    const value = try parse_positive_usize(raw);
    if value > 65535 {
        throw ConfigError.invalid_value;
    }
    return value as u16;
}

pub fn telemetry_console_settings(): TelemetryConsoleSettings ! ConfigError {
    var enabled = false;
    var port: u16 = 0;
    if env_get("RUNTIME_TELEMETRY_CONSOLE") is raw_enabled {
        enabled = try parse_bool(raw_enabled);
    }
    if env_get("RUNTIME_TELEMETRY_CONSOLE_PORT") is raw_port {
        port = try parse_port(raw_port);
    }
    return TelemetryConsoleSettings { enabled: enabled, port: port };
}

fn space(byte: u8): bool {
    return byte == 32 or byte == 9 or byte == 13;
}

fn trim(value: string): string {
    const bytes = value.bytes();
    var start: usize = 0;
    var end = bytes.len();
    while start < end and space(bytes[start]) {
        start = start + 1;
    }
    while end > start and space(bytes[end - 1]) {
        end = end - 1;
    }
    return value.slice(start, end);
}

fn content_before_comment(value: string): string {
    const bytes = value.bytes();
    var quote: u8 = 0;
    var escaped = false;
    var index: usize = 0;
    while index < bytes.len() {
        const byte = bytes[index];
        if escaped {
            escaped = false;
        } else if quote != 0 and byte == 92 {
            escaped = true;
        } else if quote != 0 {
            if byte == quote {
                quote = 0;
            }
        } else if byte == 34 or byte == 39 {
            quote = byte;
        } else if byte == 35 and (index == 0 or space(bytes[index - 1])) {
            return trim(value.slice(0, index));
        }
        index = index + 1;
    }
    return trim(value);
}

fn load_line(raw: string): i32 {
    var line = trim(raw);
    if line.len() == 0 or line.starts_with("#") {
        return 0;
    }
    if line.starts_with("export ") {
        line = trim(line.slice(7, line.len()));
    }
    const bytes = line.bytes();
    var equals = bytes.len();
    var index: usize = 0;
    while index < bytes.len() {
        if bytes[index] == 61 {
            equals = index;
            break;
        }
        index = index + 1;
    }
    if equals == bytes.len() {
        return 0;
    }
    const key = trim(line.slice(0, equals));
    if key.len() == 0 {
        return 0;
    }
    const raw_value = content_before_comment(line.slice(equals + 1, line.len()));
    const content = raw_value.bytes();
    var value = raw_value.clone();
    if content.len() >= 2 and ((content[0] == 34 and content[content.len() - 1] == 34) or
                               (content[0] == 39 and content[content.len() - 1] == 39)) {
        value = raw_value.slice(1, raw_value.len() - 1);
    }
    if env_get(key.clone()) is existing {
        return 0;
    }
    env_set(key, value) catch (code) {
        return 1;
    };
    return 0;
}

pub fn load_dotenv(): i32 {
    var path = ".env";
    var required = false;
    if env_get("DOTENV") is configured {
        if configured.len() == 0 {
            return 0;
        }
        path = configured;
        required = true;
    }
    if not required {
        const found = exists(path.clone()) catch (code) => false;
        if not found {
            return 0;
        }
    }
    const content = read_file_limited(path, 1024 * 1024);
    if content is none {
        return 1;
    }
    const bytes = content.bytes();
    var start: usize = 0;
    var index: usize = 0;
    while index <= bytes.len() {
        if index == bytes.len() or bytes[index] == 10 {
            if load_line(content.slice(start, index)) != 0 {
                return 1;
            }
            start = index + 1;
        }
        index = index + 1;
    }
    return 0;
}
