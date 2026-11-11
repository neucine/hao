import { args, exe_path } from std.process;
import { read_file_limited } from .fs;
import { script_read_error } from .fs_limit;
import { Runtime } from .runtime;
import { install } from .std;
import { collect, sort } from .std.test_files;
import { load_dotenv, telemetry_console_settings, native_stack_trace_enabled } from .config;
import { run as run_jupyter } from .jupyter.main;
import { install as install_jupyter } from .jupyter.install;
import { string as hao_version } from .version;

extern c("write") fn write_fd(fd: c_int, bytes: *const c_uchar, count: c_size_t): c_long;
extern c("hao_test_print_load") fn test_print_load(index: c_size_t, total: c_size_t, path: *const c_uchar, length: c_size_t): void;
extern c("hao_runtime_size_settings_valid") fn size_settings_valid(): c_int;
extern c("hao_runtime_trace_limit_exceeded") fn trace_limit_exceeded(): c_int;

fn write_stderr(message: string): void {
    const bytes = message.bytes();
    if write_fd(2, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) < 0 { return; }
}

fn usage(): void {
    const message = "Usage:\n  hao <file.ts|file.js>\n  hao test [--grep pattern] <file-or-dir>...\n  hao jupyter --connection-file <file>\n  hao jupyter install\n  hao --version\n";
    const bytes = message.bytes();
    if write_fd(2, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) < 0 {
        return;
    }
}

fn run_file(host: &const Runtime, path: string, test_file: bool): i32 {
    const source = read_file_limited(path.clone(), 10 * 1024 * 1024);
    if source is content {
        if test_file { return host.eval_test(content, path); }
        return host.eval(content, path);
    }
    const bytes = path.bytes();
    const reason = script_read_error(bytes.ptr as! *const c_uchar, bytes.len() as c_size_t,
        10 * 1024 * 1024);
    if reason == 2 {
        write_stderr("NameTooLong\n");
    } else if reason == 1 {
        write_stderr("StreamTooLong\n");
    } else if reason == 0 {
        write_stderr("FileNotFound\n");
    } else {
        write_stderr("FileReadFailed\n");
    }
    if test_file { return 2; }
    return 1;
}

fn main(): i32 {
    const dotenv_status = load_dotenv();
    if dotenv_status != 0 {
        if dotenv_status == 2 {
            write_stderr("error: FileNotFound\n");
        } else if dotenv_status == 3 {
            write_stderr("error: StreamTooLong\n");
        } else if dotenv_status == 4 {
            write_stderr("error: NameTooLong\n");
        } else if dotenv_status == 6 {
            write_stderr("error: InvalidEnvValue\n");
        } else if dotenv_status == 7 {
            write_stderr("error: InvalidEnvName\n");
        } else {
            write_stderr("error: FileReadFailed\n");
        }
        return 1;
    }
    // Zig loads and validates configuration before dispatching even --version.
    if size_settings_valid() == 0 {
        write_stderr("error: BadConfigValue\n");
        return 1;
    }
    const console_settings = telemetry_console_settings() catch (code) {
        write_stderr("error: BadConfigValue\n");
        return 1;
    };
    const native_stack_setting = native_stack_trace_enabled() catch (code) {
        write_stderr("error: BadConfigValue\n");
        return 1;
    };
    const arguments = args();
    if arguments.len() < 2 {
        usage();
        return 2;
    }
    if arguments.len() == 2 and (arguments[1] == "--version" or arguments[1] == "-v") {
        println($"hao {hao_version}");
        return 0;
    }
    if arguments[1] == "jupyter" {
        if arguments.len() >= 3 and arguments[2] == "install" {
            return install_jupyter();
        }
        if arguments.len() == 4 and arguments[2] == "--connection-file" {
            const status = run_jupyter(arguments[3].clone());
            if status == -1 { write_stderr("error: FileNotFound\n"); }
            if status == -2 { write_stderr("error: StreamTooLong\n"); }
            if status == -3 { write_stderr("error: NameTooLong\n"); }
            if status == -4 { write_stderr("error: FileReadFailed\n"); }
            if status == -5 { write_stderr("error: MissingField\n"); }
            if status == -6 { write_stderr("error: ZmqError\n"); }
            if status < 0 { return 1; }
            return status;
        }
        usage();
        return 2;
    }
    const is_test = arguments[1] == "test";
    if not is_test and arguments.len() != 2 {
        usage();
        return 2;
    }
    var test_files: List<string> = list<string>();
    var grep = "";
    var provided_test_path = false;
    if is_test {
        var index: usize = 2;
        while index < arguments.len() {
            if arguments[index] == "--grep" {
                if index + 1 >= arguments.len() {
                    usage();
                    return 2;
                }
                grep = arguments[index + 1].clone();
                index = index + 2;
            } else {
                provided_test_path = true;
                if collect(arguments[index].clone(), &test_files) != 0 {
                    println("Unable to discover test files");
                    return 1;
                }
                index = index + 1;
            }
        }
        if not provided_test_path {
            usage();
            return 2;
        }
        sort(&test_files);
    }
    if trace_limit_exceeded() != 0 {
        write_stderr("error: TelemetryTraceLimitExceeded\n");
        return 1;
    }
    const runtime = Runtime.init();
    if runtime is host {
        defer host.deinit();
        if install(&host) != 0 {
            println("Unable to install standard modules");
            return 1;
        }
        if is_test {
            if host.eval("globalThis.__hao_test_started_ns = __hao_telemetry_monotonicNs();",
                "<hao-test-timing>") != 0 { return 1; }
            if host.eval("import 'std:test';", "<hao-test-setup>") != 0 { return 1; }
            var files_loaded: usize = 0;
            var file_failures: usize = 0;
            const files_total = test_files.len();
            write_stderr($"Found {files_total} test file(s)\n");
            const executable = exe_path() catch (code) {
                println("Unable to find Hao executable");
                return 1;
            };
            if host.set_executable_path(executable) != 0 {
                return 1;
            }
            var file_index: usize = 0;
            for path in test_files {
                file_index = file_index + 1;
                const path_bytes = path.bytes();
                test_print_load(file_index as c_size_t, files_total as c_size_t,
                    path_bytes.ptr as! *const c_uchar, path_bytes.len() as c_size_t);
                const load_status = run_file(&host, path.clone(), true);
                if load_status == 2 { return 1; }
                if load_status != 0 or host.drain_test_jobs(path.clone()) < 0 {
                    file_failures = file_failures + 1;
                } else {
                    files_loaded = files_loaded + 1;
                }
            }
            if host.set_test_file_counts(files_loaded, file_failures, files_total) != 0 { return 1; }
            if host.start_tests(grep) != 0 {
                return 1;
            }
            if host.run_until_idle() != 0 {
                return 1;
            }
            if file_failures != 0 or host.test_failures() != 0 {
                return 1;
            }
            return 0;
        } else {
            if run_file(&host, arguments[1].clone(), false) != 0 {
                return 1;
            }
        }
        const loop_status = host.run_until_idle();
        if loop_status != 0 {
            return loop_status;
        }
        return 0;
    }
    println("Unable to initialize JavaScript runtime");
    return 1;
}
