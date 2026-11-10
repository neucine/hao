import { command, env_get } from std.process;
import { Value, parse } from std.json;
import { copy_bytes, copy_output, text_from_c } from .c_bytes;

pub c struct RunResult {
    pub stdout_len: c_size_t;
    pub stderr_len: c_size_t;
    pub exit_code: c_int;
    pub has_exit_code: c_int;
}

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

export c("hao_process_get_env") fn get_env(name_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    const name = text_from_c(name_pointer);
    if env_get(name) is value {
        const bytes = value.bytes();
        if bytes.len() >= capacity as usize {
            return -2;
        }
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        return bytes.len() as c_int;
    }
    return -1;
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
            var builder = command(program);
            for value in values {
                builder = builder.arg(value.clone());
            }
            if field(&options, "cwd") is directory {
                builder = builder.cwd(directory);
            }
            const output = builder.output() catch (code) {
                return 2;
            };
            const stdout_bytes = output.stdout.bytes();
            const stderr_bytes = output.stderr.bytes();
            if stdout_bytes.len() > capacity as usize or stderr_bytes.len() > capacity as usize {
                return 3;
            }
            copy_output(stdout_output, stdout_bytes.ptr as! *const c_uchar, stdout_bytes.len() as c_size_t);
            copy_output(stderr_output, stderr_bytes.ptr as! *const c_uchar, stderr_bytes.len() as c_size_t);
            unchecked {
                (*result).stdout_len = stdout_bytes.len() as c_size_t;
                (*result).stderr_len = stderr_bytes.len() as c_size_t;
                if output.status.code is code {
                    (*result).exit_code = code as c_int;
                    (*result).has_exit_code = 1;
                } else {
                    (*result).exit_code = 0;
                    (*result).has_exit_code = 0;
                }
            }
            return 0;
        }
    }
    return 1;
}
