import { read_file } from std.fs;
import { join, dirname } from std.path;
import { exe_path } from std.process;
import { Runtime } from .runtime;
import { fs_exists } from .fs;
import { resolve_package } from .package;
import { get_env } from .std.process.native;

fn install_one(runtime: &const Runtime, directory: string, name: string, filename: string): i32 {
    const parts: [2]string = [directory.clone(), filename];
    const path = join(parts[..]);
    const source = read_file(path) catch (code) {
        return 1;
    };
    return runtime.register_source_module(name, source);
}

pub fn install_from(runtime: &const Runtime, module_directory: string): i32 {
    if install_one(runtime, module_directory, "std:runtime", "runtime.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:fs/native", "fs_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory, "std:fs", "fs.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:process/native", "process_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory, "std:process", "process.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:plot", "plot.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:util/native", "util_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:util", "util.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:http/native", "http_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:http", "http.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:http/server", "http_server.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:telemetry/native", "telemetry_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:telemetry/dashboard", "telemetry_dashboard.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:telemetry/console", "telemetry_console.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:telemetry", "telemetry.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/native", "ffi_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/ast", "ffi_c_abi_ast.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/metadata", "ffi_c_abi_metadata.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/errors", "ffi_c_abi_errors.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/lower", "ffi_c_abi_lower.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/parser", "ffi_c_abi_parser.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c_abi/struct_runtime", "ffi_c_abi_struct_runtime.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c/native", "ffi_c_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi/c", "ffi_c.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:ffi", "ffi.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:test/native", "test_native.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory, "std:test", "test.ts") != 0 {
        return 1;
    }
    return runtime.eval("import 'std:telemetry/console'; import { inspect } from 'std:util'; globalThis.__hao_jupyter_inspect = inspect; globalThis.__hao_console_inspect = inspect;", "<hao-runtime-helpers>");
}

pub fn install(runtime: &const Runtime): i32 {
    const executable = exe_path() catch (code) {
        return 1;
    };
    const binary_directory = dirname(executable);
    const parts: [2]string = [binary_directory, "modules"];
    return install_from(runtime, join(parts[..]));
}
