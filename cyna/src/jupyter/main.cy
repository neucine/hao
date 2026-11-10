import { Value, parse as parse_json, encode } from std.json;
import { Runtime } from .runtime;
import { install } from .std;
import { parse as parse_connection } from .jupyter.connection;
import { Wire } from .jupyter.wire;

struct HistoryEntry {
    line: u32;
    code: string;
}

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

fn number_field(value: &const Value, key: string, fallback: u32): u32 {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .number(number) => {
                        const bytes = number.spelling.bytes();
                        if bytes.len() == 0 or bytes.len() > 10 { return fallback; }
                        var result: u64 = 0;
                        for byte in bytes {
                            if byte < 48 or byte > 57 { return fallback; }
                            result = result * 10 + (byte - 48) as u64;
                            if result > 4294967295 { return fallback; }
                        }
                        return result as u32;
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return fallback;
}

fn history_reply(history: &const List<HistoryEntry>, content: &const Value, count: u32): string {
    const access = text_or_empty(field(content, "hist_access_type"));
    const n = number_field(content, "n", 10);
    const start = number_field(content, "start", 1);
    const stop = number_field(content, "stop", 4294967295);
    var result = "{\"status\":\"ok\",\"history\":[";
    var index: usize = 0;
    var first = true;
    while index < history.len() {
        var slot = index;
        if history.len() == 128 {
            slot = (count as usize + index) % 128;
        }
        const entry = history[slot];
        var include = false;
        if access == "range" {
            include = entry.line >= start and entry.line < stop;
        } else {
            include = access == "" or access == "tail";
            if include and n < history.len() as u32 {
                include = index >= history.len() - n as usize;
            }
        }
        if include {
            if not first { result = $"{result},"; }
            const code = json_string(entry.code);
            result = $"{result}[1,{entry.line},{code}]";
            first = false;
        }
        index = index + 1;
    }
    return $"{result}]\}";
}

fn remember(history: &List<HistoryEntry>, line: u32, code: string): void {
    if history.len() >= 128 {
        history[((line - 1) % 128) as usize] = HistoryEntry { line: line, code: code };
    } else {
        history.push(HistoryEntry { line: line, code: code });
    }
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

fn user_expressions(runtime: &const Runtime, content: &const Value, serial: u32): string {
    var result = "{";
    switch content {
        .object(request) => {
            if request.contains("user_expressions") {
                switch request["user_expressions"] {
                    .object(expressions) => {
                        var index: usize = 0;
                        for member in expressions.members {
                            switch member.value {
                                .string(expression) => {
                                    if index != 0 { result = $"{result},"; }
                                    const key = json_string(member.key);
                                    const filename = $"<hao-jupyter-expression-{serial}-{index}>";
                                    const packet_text = runtime.eval_cell(expression, filename);
                                    if packet_text is text {
                                        const packet = parse_json(text) catch (error) { return "{}"; };
                                        const value = text_or_empty(field(&packet, "value"));
                                        const escaped = json_string(value);
                                        if boolean(&packet, "error") {
                                            result = $"{result}{key}:\{\"status\":\"error\",\"ename\":\"Error\",\"evalue\":{escaped},\"traceback\":[{escaped}]\}";
                                        } else {
                                            const mime = text_or_empty(field(&packet, "mime"));
                                            var kind = "text/plain";
                                            if mime != "" { kind = mime; }
                                            const escaped_mime = json_string(kind);
                                            result = $"{result}{key}:\{\"status\":\"ok\",\"data\":\{{escaped_mime}:{escaped}\},\"metadata\":\{\}\}";
                                        }
                                    } else { return "{}"; }
                                    index = index + 1;
                                }
                                _ => {}
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return $"{result}\}";
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
            const expressions = user_expressions(runtime, content, serial);
            const reply = $"\{\"status\":\"ok\",\"execution_count\":{reply_count},\"user_expressions\":{expressions}\}";
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
            var history: List<HistoryEntry> = list<HistoryEntry>();
            while true {
                const channel = transport.poll(100);
                if channel == 0 or channel == 1 or channel == -1 { continue; }
                const header_text = text_or_empty(transport.header());
                const content_text = text_or_empty(transport.content());
                const header = parse_json(header_text) catch (error) { continue; };
                const content = parse_json(content_text) catch (error) { continue; };
                if field(&header, "msg_type") is kind {
                    if kind == "shutdown_request" and channel == 2 {
                        var restart = "false";
                        if boolean(&content, "restart") { restart = "true"; }
                        const reply = $"\{\"status\":\"ok\",\"restart\":{restart}\}";
                        if transport.send(2, "shutdown_reply", reply) != 0 { return 1; }
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
                    } else if kind == "complete_request" {
                        const cursor = number_field(&content, "cursor_pos", 0);
                        const reply = $"\{\"matches\":[],\"cursor_start\":{cursor},\"cursor_end\":{cursor},\"metadata\":\{\},\"status\":\"ok\"\}";
                        if transport.send(3, "complete_reply", reply) != 0 { return 1; }
                    } else if kind == "inspect_request" {
                        if transport.send(3, "inspect_reply", "{\"status\":\"ok\",\"found\":false,\"data\":{},\"metadata\":{}}") != 0 { return 1; }
                    } else if kind == "history_request" {
                        if transport.send(3, "history_reply", history_reply(&history, &content, count)) != 0 { return 1; }
                    } else if kind == "execute_request" {
                        serial = serial + 1;
                        const silent = boolean(&content, "silent");
                        if not silent and not is_false(&content, "store_history") {
                            count = count + 1;
                            if field(&content, "code") is code {
                                remember(&history, count, code);
                            }
                        }
                        if execute(&transport, &host, &content, count, serial, silent) != 0 { return 1; }
                    }
                }
            }
        }
    }
    return 1;
}
