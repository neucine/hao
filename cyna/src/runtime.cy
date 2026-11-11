import { text_from_c } from .c_bytes;
import { Loop } from .async.loop;
import { install as install_console } from .global.console;
import { install as install_timer } from .global.timer;
import { eval as eval_module, register_source } from .modules;
import { telemetry_console_settings, native_stack_trace_enabled } from .config;
import { host as telemetry_host } from .telemetry.interface;
import { Backend } from std.telemetry;

extern c("hao_runtime_new") fn runtime_new(): c_size_t;
extern c("hao_runtime_free") fn runtime_free(handle: c_size_t): void;
extern c("hao_runtime_start_tests") fn runtime_start_tests(handle: c_size_t, grep: *const c_uchar, grep_len: c_size_t): c_int;
extern c("hao_runtime_test_failures") fn runtime_test_failures(handle: c_size_t): c_int;
extern c("hao_runtime_discard_test_file") fn runtime_discard_test_file(handle: c_size_t, path: *const c_uchar, path_len: c_size_t): c_int;
extern c("hao_runtime_set_executable") fn runtime_set_executable(handle: c_size_t, path: *const c_uchar, path_len: c_size_t): c_int;
extern c("hao_runtime_eval_cell") fn runtime_eval_cell(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): ?*const c_uchar;
extern c("hao_runtime_free_text") fn runtime_free_text(text: *const c_uchar): void;
extern c("hao_runtime_set_telemetry_console") fn runtime_set_telemetry_console(handle: c_size_t, enabled: c_int, port: c_ushort): void;
extern c("hao_runtime_set_native_stack_trace") fn runtime_set_native_stack_trace(handle: c_size_t, enabled: c_int): void;

pub struct Runtime {
    pub handle: c_size_t;

    pub fn init(): ?Runtime {
        const console = telemetry_console_settings() catch (code) {
            return none;
        };
        const native_stack = native_stack_trace_enabled() catch (code) {
            return none;
        };
        const handle = runtime_new();
        if handle == 0 {
            return none;
        }
        if install_console(handle) != 0 or install_timer(handle) != 0 {
            runtime_free(handle);
            return none;
        }
        var console_enabled: c_int = 0;
        if console.enabled {
            console_enabled = 1;
        }
        runtime_set_telemetry_console(handle, console_enabled, console.port as c_ushort);
        var stack_enabled: c_int = 0;
        if native_stack { stack_enabled = 1; }
        runtime_set_native_stack_trace(handle, stack_enabled);
        return Runtime {
            handle: handle
        };
    }

    pub fn deinit(self: Runtime): void {
        runtime_free(self.handle);
    }

    pub fn telemetry(self: &const Runtime): Backend {
        return telemetry_host(self.handle as usize);
    }

    pub fn eval(self: &const Runtime, source: string, filename: string): i32 {
        return eval_module(self.handle, source, filename);
    }

    pub fn eval_cell(self: &const Runtime, source: string, filename: string): ?string {
        const source_bytes = source.bytes();
        const name_bytes = filename.bytes();
        if runtime_eval_cell(self.handle, source_bytes.ptr as! *const c_uchar,
            source_bytes.len() as c_size_t, name_bytes.ptr as! *const c_uchar,
            name_bytes.len() as c_size_t) is pointer {
            const packet = text_from_c(pointer);
            runtime_free_text(pointer);
            return packet;
        }
        return none;
    }

    pub fn run_until_idle(self: &const Runtime): i32 {
        const loop = Loop { handle: self.handle };
        return loop.run_until_idle();
    }

    pub fn drain_jobs(self: &const Runtime): i32 {
        const loop = Loop { handle: self.handle };
        return loop.drain_jobs();
    }

    pub fn register_source_module(self: &const Runtime, name: string, source: string): i32 {
        return register_source(self.handle, name, source);
    }

    pub fn start_tests(self: &const Runtime, grep: string): i32 {
        const bytes = grep.bytes();
        return runtime_start_tests(self.handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) as i32;
    }

    pub fn test_failures(self: &const Runtime): i32 {
        return runtime_test_failures(self.handle) as i32;
    }

    pub fn discard_test_file(self: &const Runtime, path: string): i32 {
        const bytes = path.bytes();
        return runtime_discard_test_file(self.handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) as i32;
    }

    pub fn set_executable_path(self: &const Runtime, path: string): i32 {
        const bytes = path.bytes();
        return runtime_set_executable(self.handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) as i32;
    }
}
