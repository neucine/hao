import { Value, parse as parse_json, encode } from std.json;
import { Runtime } from .runtime;
import { install } from .std_modules;
import { parse as parse_connection } from .jupyter_connection;
import { Wire } from .jupyter_wire;

fn field(value: &const Value, key: string): ?string {
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

fn boolean(value: &const Value, key: string): bool {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .bool(flag) => { return flag; }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return false;
}

fn is_false(value: &const Value, key: string): bool {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .bool(flag) => { return not flag; }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return false;
}

fn json_string(text: string): string {
    const value: Value = .string(text);
    return encode(&value);
}

fn text_or_empty(value: ?string): string {
    if value is present { return present; }
    return "";
}

fn send_status(wire: &const Wire, state: string): i32 {
    const escaped = json_string(state);
    return wire.send(4, "status", $"\{\"execution_state\":{escaped}\}");
}

fn send_stream(wire: &const Wire, name: string, output: string): i32 {
    if output.len() == 0 { return 0; }
    const escaped_name = json_string(name);
    const escaped_output = json_string(output);
    return wire.send(4, "stream", $"\{\"name\":{escaped_name},\"text\":{escaped_output}\}");
}

fn execute(wire: &const Wire, runtime: &const Runtime, content: &const Value, count: u32, serial: u32, silent: bool): i32 {
    const code = field(content, "code");
    if code is none { return 1; }
    if send_status(wire, "busy") != 0 { return 1; }
    if not silent {
        const escaped_code = json_string(code);
        const input = $"\{\"code\":{escaped_code},\"execution_count\":{count}\}";
        if wire.send(4, "execute_input", input) != 0 { return 1; }
    }
    const filename = $"<hao-jupyter-cell-{serial}>";
    const packet_text = runtime.eval_cell(code, filename);
    if packet_text is none { return 1; }
    const packet = parse_json(packet_text) catch (error) { return 1; };
    if not silent {
        if field(&packet, "stdout") is output {
            if send_stream(wire, "stdout", output) != 0 { return 1; }
        }
        if field(&packet, "stderr") is output {
            if send_stream(wire, "stderr", output) != 0 { return 1; }
        }
    }
    if field(&packet, "value") is value {
        if boolean(&packet, "error") {
            const escaped = json_string(value);
            const error_content = $"\{\"ename\":\"Error\",\"evalue\":{escaped},\"traceback\":[{escaped}]\}";
            if not silent and wire.send(4, "error", error_content) != 0 { return 1; }
            var reply_count = $"{count}";
            if silent { reply_count = "null"; }
            const reply = $"\{\"status\":\"error\",\"execution_count\":{reply_count},\"ename\":\"Error\",\"evalue\":{escaped},\"traceback\":[{escaped}]\}";
            if wire.send(3, "execute_reply", reply) != 0 { return 1; }
        } else {
            if not silent and boolean(&packet, "has_value") {
                const escaped_value = json_string(value);
                const mime = text_or_empty(field(&packet, "mime"));
                if mime != "" and mime != "text/plain" {
                    const escaped_mime = json_string(mime);
                    const display = $"\{\"data\":\{{escaped_mime}:{escaped_value}\},\"metadata\":\{\},\"transient\":\{\}\}";
                    if wire.send(4, "display_data", display) != 0 { return 1; }
                } else {
                    const result = $"\{\"execution_count\":{count},\"data\":\{\"text/plain\":{escaped_value}\},\"metadata\":\{\}\}";
                    if wire.send(4, "execute_result", result) != 0 { return 1; }
                }
            }
            var reply_count = $"{count}";
            if silent { reply_count = "null"; }
            const reply = $"\{\"status\":\"ok\",\"execution_count\":{reply_count},\"user_expressions\":\{\}\}";
            if wire.send(3, "execute_reply", reply) != 0 { return 1; }
        }
    }
    return send_status(wire, "idle");
}

pub fn run(path: string): i32 {
    const connection = parse_connection(path);
    if connection is none { return 1; }
    if connection.signature_scheme != "hmac-sha256" { return 1; }
    const wire = Wire.open(&connection);
    if wire is transport {
        defer transport.deinit();
        const runtime = Runtime.init();
        if runtime is host {
            defer host.deinit();
            if install(&host) != 0 { return 1; }
            var count: u32 = 0;
            var serial: u32 = 0;
            while true {
                const channel = transport.poll(100);
                if channel == 0 or channel == 1 or channel == -1 { continue; }
                const header_text = text_or_empty(transport.header());
                const content_text = text_or_empty(transport.content());
                const header = parse_json(header_text) catch (error) { continue; };
                const content = parse_json(content_text) catch (error) { continue; };
                if field(&header, "msg_type") is kind {
                    if kind == "shutdown_request" and channel == 2 {
                        if transport.send(2, "shutdown_reply", "{\"status\":\"ok\",\"restart\":false}") != 0 { return 1; }
                        return 0;
                    }
                    if channel != 3 { continue; }
                    if kind == "kernel_info_request" {
                        if send_status(&transport, "busy") != 0 { return 1; }
                        const info = "{\"protocol_version\":\"5.3\",\"implementation\":\"hao\",\"implementation_version\":\"0.1.2\",\"language_info\":{\"name\":\"typescript\",\"version\":\"5.0\",\"mimetype\":\"text/typescript\",\"file_extension\":\".ts\",\"codemirror_mode\":{\"name\":\"javascript\",\"typescript\":true}},\"banner\":\"Hao JS - embedded TypeScript/JavaScript runtime\",\"status\":\"ok\"}";
                        if transport.send(3, "kernel_info_reply", info) != 0 or send_status(&transport, "idle") != 0 { return 1; }
                    } else if kind == "is_complete_request" {
                        if transport.send(3, "is_complete_reply", "{\"status\":\"complete\"}") != 0 { return 1; }
                    } else if kind == "comm_info_request" {
                        if transport.send(3, "comm_info_reply", "{\"comms\":{},\"status\":\"ok\"}") != 0 { return 1; }
                    } else if kind == "execute_request" {
                        serial = serial + 1;
                        const silent = boolean(&content, "silent");
                        if not silent and not is_false(&content, "store_history") { count = count + 1; }
                        if execute(&transport, &host, &content, count, serial, silent) != 0 { return 1; }
                    }
                }
            }
        }
    }
    return 1;
}
