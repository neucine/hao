import { Value, parse } from std.json;
import { copy_bytes } from .c_bytes;

import { execute, RunResult } from .std.process.execute;

fn field(value: &const Value, key: string): ?string {
    switch value {
        .object(object) => {
            if object.contains(key) {
                switch object[key] {
                    .string(text) => {
                        return text.clone();
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return none;
}

fn arguments(value: &const Value): ?List<string> {
    var result: List<string> = list<string>();
    switch value {
        .object(object) => {
            if object.contains("args") {
                switch object["args"] {
                    .array(array) => {
                        var index: usize = 0;
                        while index < array.len() {
                            switch array[index] {
                                .string(text) => {
                                    result.push(text.clone());
                                }
                                _ => {
                                    return none;
                                }
                            }
                            index = index + 1;
                        }
                    }
                    _ => {
                        return none;
                    }
                }
            }
        }
        _ => {
            return none;
        }
    }
    return result;
}

export c("hao_process_run_json") fn run_json(options_pointer: *const c_uchar, options_len: c_size_t, stdout_output: *c_uchar, stderr_output: *c_uchar, capacity: c_size_t, result: *RunResult): c_int {
    const bytes = copy_bytes(options_pointer, options_len as usize);
    const options = parse(string.from(bytes[..])) catch (code) {
        return 1;
    };
    const cmd = field(&options, "cmd");
    if cmd is program {
        const args = arguments(&options);
        if args is values {
            var argument_bytes: List<u8> = list<u8>();
            for value in values {
                const value_bytes = value.bytes();
                for byte in value_bytes {
                    if byte == 0 { break; }
                    argument_bytes.push(byte);
                }
                argument_bytes.push(0);
            }
            const program_bytes = program.bytes();
            var program_len: usize = 0;
            for byte in program_bytes {
                if byte == 0 { break; }
                program_len = program_len + 1;
            }
            if program_len == 0 { return 3; }
            if field(&options, "cwd") is directory {
                const cwd_bytes = directory.bytes();
                var cwd_len: usize = 0;
                for byte in cwd_bytes {
                    if byte == 0 { break; }
                    cwd_len = cwd_len + 1;
                }
                if cwd_len == 0 { return 3; }
                return execute(program_bytes.ptr as! *const c_uchar, program_len as c_size_t,
                    argument_bytes.view().ptr as! *const c_uchar, argument_bytes.len() as c_size_t, values.len() as c_size_t,
                    cwd_bytes.ptr as! *const c_uchar, cwd_len as c_size_t,
                    stdout_output, stderr_output, capacity, result);
            }
            const empty = "".bytes();
            return execute(program_bytes.ptr as! *const c_uchar, program_len as c_size_t,
                argument_bytes.view().ptr as! *const c_uchar, argument_bytes.len() as c_size_t, values.len() as c_size_t,
                empty.ptr as! *const c_uchar, 0, stdout_output, stderr_output, capacity, result);
        }
    }
    return 1;
}
