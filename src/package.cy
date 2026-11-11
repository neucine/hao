import { read_file_limited } from .fs;
import { dirname, join } from std.path;
import { env_get } from std.process;
import { Value, parse } from std.json;
import { copy_output, text_from_c } from .c_bytes;

extern c("hao_fs_path_exists_len") fn path_exists_len(path: *const c_uchar, length: c_size_t): c_int;

fn path_exists(path: string): bool {
    const bytes = path.bytes();
    return path_exists_len(bytes.ptr as! *const c_uchar, bytes.len() as c_size_t) != 0;
}

struct Resolution {
    path: ?string;
    error: i32;
}

fn failed(code: i32): Resolution {
    return Resolution { path: none, error: code };
}

fn found(path: string): Resolution {
    return Resolution { path: path, error: 0 };
}

fn join2(first: string, second: string): string {
    const parts: [2]string = [first.clone(), second.clone()];
    return join(parts[..]);
}

fn trim_root(value: string): string {
    const bytes = value.bytes();
    var start: usize = 0;
    var end = bytes.len();
    while start < end and (bytes[start] == 32 or bytes[start] == 9 or bytes[start] == 13 or bytes[start] == 10) {
        start = start + 1;
    }
    while end > start and (bytes[end - 1] == 32 or bytes[end - 1] == 9 or bytes[end - 1] == 13 or bytes[end - 1] == 10) {
        end = end - 1;
    }
    return value.slice(start, end);
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

fn nested_field(value: &const Value, outer: string, inner: string): ?string {
    switch value {
        .object(object) => {
            if object.contains(outer) {
                return field(&object[outer], inner);
            }
        }
        _ => {}
    }
    return none;
}

fn import_field(value: &const Value, outer: string, inner: string): ?string {
    switch value {
        .object(object) => {
            if object.contains(outer) {
                return nested_field(&object[outer], inner, "import");
            }
        }
        _ => {}
    }
    return none;
}

fn package_name(specifier: string): string {
    const bytes = specifier.bytes();
    var index: usize = 0;
    if specifier.starts_with("@") {
        while index < bytes.len() and bytes[index] != 47 {
            index = index + 1;
        }
        if index == bytes.len() { return specifier.clone(); }
        index = index + 1;
        while index < bytes.len() {
            if bytes[index] == 47 or bytes[index] == 58 {
                return specifier.slice(0, index);
            }
            index = index + 1;
        }
        return specifier.clone();
    }
    while index < bytes.len() {
        if bytes[index] == 58 { return specifier.slice(0, index); }
        index = index + 1;
    }
    index = 0;
    while index < bytes.len() {
        if bytes[index] == 47 { return specifier.slice(0, index); }
        index = index + 1;
    }
    return specifier.clone();
}

fn entry_for(manifest: &const Value, subpath: string): ?string {
    if subpath.len() > 0 {
        const key = $"./{subpath}";
        if import_field(manifest, "exports", key) is imported {
            return imported;
        }
        return nested_field(manifest, "exports", key);
    }
    if import_field(manifest, "exports", ".") is imported {
        return imported;
    }
    if nested_field(manifest, "exports", ".") is direct {
        return direct;
    }
    if field(manifest, "exports") is direct {
        return direct;
    }
    return field(manifest, "main");
}

fn supported_entry(path: string, package_type: ?string): bool {
    if path.ends_with(".dylib") or path.ends_with(".so") or path.ends_with(".dll") or path.ends_with(".node") {
        return true;
    }
    if path.ends_with(".ts") or path.ends_with(".mts") or path.ends_with(".mjs") {
        return true;
    }
    if path.ends_with(".js") {
        if package_type is kind {
            return kind == "module";
        }
    }
    return false;
}

fn find_entry(root: string, entry: string, package_type: ?string): Resolution {
    var relative = entry.clone();
    if entry.starts_with("./") {
        relative = entry.slice(2, entry.len());
    } else if entry.starts_with("/") {
        var start: usize = 0;
        const bytes = entry.bytes();
        while start < bytes.len() and bytes[start] == 47 {
            start = start + 1;
        }
        relative = entry.slice(start, entry.len());
    }
    const extensions: [9]string = ["", ".ts", ".js", ".mts", ".mjs", ".dylib", ".so", ".dll", ".node"];
    for extension in extensions {
        const candidate = $"{relative}{extension}";
        const path = join2(root, candidate);
        // Keep a trailing separator for access(2): a file followed by '/' is
        // missing, while a directory followed by '/' still exists.
        const access_path = $"{root}/{candidate}";
        if path_exists(access_path) {
            if supported_entry(candidate, package_type) { return found(path); }
            return failed(-3);
        }
    }
    return failed(-1);
}

fn resolve_in(root: string, subpath: string): Resolution {
    const manifest_path = join2(root, "package.json");
    const maybe_source = read_file_limited(manifest_path.clone(), 256 * 1024);
    if maybe_source is source {
        const manifest = parse(source) catch (code) {
            return failed(-1);
        };
        if field(&manifest, "type") is kind {
            if kind == "commonjs" {
                return failed(-2);
            }
        }
        if entry_for(&manifest, subpath) is entry {
            return find_entry(root, entry, field(&manifest, "type"));
        }
        return failed(-5);
    } else {
        const present = path_exists(manifest_path);
        if present { return failed(-1); }
        return failed(-4);
    }
}

fn resolve(base: string, specifier: string): Resolution {
    const name = package_name(specifier);
    if name.len() == 0 or name == "std" {
        return failed(-1);
    }
    var subpath = "";
    if name.len() < specifier.len() {
        subpath = specifier.slice(name.len() + 1, specifier.len());
    }
    if env_get("RUNTIME_PACKAGE_PATH") is roots {
        var start: usize = 0;
        const bytes = roots.bytes();
        var index: usize = 0;
        while index <= bytes.len() {
            if index == bytes.len() or bytes[index] == 58 {
                const root = trim_root(roots.slice(start, index));
                if root.len() > 0 {
                    const package_root = join2(root, name);
                    const found = path_exists(package_root.clone());
                    if found {
                        return resolve_in(package_root, subpath);
                    }
                }
                start = index + 1;
            }
            index = index + 1;
        }
    }
    var directory = dirname(base);
    while directory.len() > 0 {
        const node_modules = join2(directory, "node_modules");
        const package_root = join2(node_modules, name);
        const found = path_exists(package_root.clone());
        if found {
            return resolve_in(package_root, subpath);
        }
        const parent = dirname(directory);
        if parent == directory {
            break;
        }
        directory = parent;
    }
    return failed(-1);
}

export c("hao_resolve_package") fn resolve_package(base_pointer: *const c_uchar, specifier_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    const base = text_from_c(base_pointer);
    const specifier = text_from_c(specifier_pointer);
    const resolution = resolve(base, specifier);
    if resolution.path is path {
        const bytes = path.bytes();
        if bytes.len() >= capacity as usize or bytes.len() > 4095 {
            return -1;
        }
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        return bytes.len() as c_int;
    }
    return resolution.error as c_int;
}
