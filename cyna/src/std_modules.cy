import { read_file } from std.fs;
import { join, dirname } from std.path;
import { exe_path } from std.process;
import { Runtime } from .runtime;
import { fs_exists } from .fs_host;
import { resolve_package } from .package_resolver;
import { get_env } from .process_host;

fn install_one(runtime: &const Runtime, directory: string, name: string, filename: string): i32 {
    const parts: [2]string = [directory.clone(), filename];
    const path = join(parts[..]);
    const source = read_file(path) catch (code) {
        return 1;
    };
    return runtime.register_source_module(name, source);
}

pub fn install(runtime: &const Runtime): i32 {
    const executable = exe_path() catch (code) {
        return 1;
    };
    const binary_directory = dirname(executable);
    const parts: [2]string = [binary_directory, "modules"];
    const module_directory = join(parts[..]);
    if install_one(runtime, module_directory, "std:runtime", "runtime.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory, "std:fs", "fs.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory, "std:process", "process.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:plot", "plot.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:util", "util.ts") != 0 {
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
    if install_one(runtime, module_directory.clone(), "std:telemetry", "telemetry.ts") != 0 {
        return 1;
    }
    if install_one(runtime, module_directory.clone(), "std:test/native", "test_native.ts") != 0 {
        return 1;
    }
    return install_one(runtime, module_directory, "std:test", "test.ts");
}
