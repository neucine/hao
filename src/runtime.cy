import { runtime_new, runtime_free, runtime_start_tests, runtime_test_failures, runtime_set_test_file_counts, runtime_set_executable, runtime_eval_cell, runtime_free_text, runtime_drain_test, runtime_set_telemetry_console, runtime_set_native_stack_trace } from .bridge;
import { text_from_c } from .c_bytes;
import { write_stderr } from .stderr;
import { Loop } from .async.loop;
import { install as install_console } from .global.console;
import { install as install_timer } from .global.timer;
import { eval as eval_module, eval_test as eval_test_module, register_source } from .modules;
import { telemetry_console_settings, native_stack_trace_enabled, runtime_size_settings } from .config;
import { host as telemetry_host } from .telemetry.interface;
import { snapshot_c } from .process_memory;
import { Backend } from std.telemetry;


pub struct Runtime {
    pub handle: c_size_t;

    pub fn init(): ?Runtime {
        const sizes = runtime_size_settings() catch (code) {
            write_stderr("Invalid Hao runtime size setting\n");
            return none;
        };
        const console = telemetry_console_settings() catch (code) {
            return none;
        };
        const native_stack = native_stack_trace_enabled() catch (code) {
            return none;
        };
        var console_enabled: c_int = 0;
        if console.enabled { console_enabled = 1; }
        const handle = runtime_new(sizes.stack_size as c_size_t, sizes.gc_threshold as c_size_t,
            sizes.thread_pool_size as c_size_t, sizes.trace_records as c_size_t, console_enabled);
        if handle == 0 {
            return none;
        }
        if install_console(handle) != 0 or install_timer(handle) != 0 {
            runtime_free(handle);
            return none;
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

    pub fn eval_test(self: &const Runtime, source: string, filename: string): i32 {
        return eval_test_module(self.handle, source, filename);
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

    pub fn drain_test_jobs(self: &const Runtime, path: string): i32 {
        const bytes = path.bytes();
        return runtime_drain_test(self.handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) as i32;
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

    pub fn set_test_file_counts(self: &const Runtime, loaded: usize, failed: usize, total: usize): i32 {
        return runtime_set_test_file_counts(self.handle, loaded as c_size_t,
            failed as c_size_t, total as c_size_t) as i32;
    }

    pub fn set_executable_path(self: &const Runtime, path: string): i32 {
        const bytes = path.bytes();
        return runtime_set_executable(self.handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) as i32;
    }
}
