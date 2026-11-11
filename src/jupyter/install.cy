import { write_file } from std.fs;
import { join } from std.path;
import { env_get, exe_path } from std.process;
import { Value, encode } from std.json;
import { make_path } from .fs;

fn join2(first: string, second: string): string {
    const parts: [2]string = [first, second];
    return join(parts[..]);
}

pub fn install(): i32 {
    const executable = exe_path() catch (code) { return 1; };
    var directory = "";
    if env_get("HAO_JUPYTER_KERNEL_DIR") is override_path {
        directory = override_path;
    } else if env_get("HOME") is user_home {
        directory = join2(user_home, "Library/Jupyter/kernels/hao");
    } else {
        return 1;
    }
    if directory.len() == 0 or make_path(directory.clone()) != 0 { return 1; }
    const executable_value: Value = .string(executable);
    const executable_json = encode(&executable_value);
    const content = $"\{\"argv\":[{executable_json},\"jupyter\",\"--connection-file\",\"\{connection_file\}\"],\"display_name\":\"Hao (TypeScript)\",\"language\":\"typescript\",\"metadata\":\{\"debugger\":false\}\}";
    const path = join2(directory, "kernel.json");
    write_file(path.clone(), content) catch (code) { return 1; };
    println($"Installed kernel to {path}");
    return 0;
}
