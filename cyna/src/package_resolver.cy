import { exists, read_file } from std.fs;
import { dirname, join } from std.path;
import { env_get } from std.process;
import { Value, parse } from std.json;
import { copy_output, text_from_c } from .c_bytes;

fn join2(first: string, second: string): string {
    const parts: [2]string = [first.clone(), second.clone()];
    return join(parts[..]);
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
    var scope_slash = false;
    const is_scoped = specifier.starts_with("@");
    while index < bytes.len() {
        const byte = bytes[index];
        if byte == 47 {
            if is_scoped and not scope_slash {
                scope_slash = true;
            } else {
                return specifier.slice(0, index);
            }
        } else if byte == 58 {
            return specifier.slice(0, index);
        }
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

fn find_entry(root: string, entry: string, package_type: ?string): ?string {
    if not entry.starts_with("./") or entry.contains("..") {
        return none;
    }
    const relative = entry.slice(2, entry.len());
    const extensions: [5]string = ["", ".ts", ".js", ".mts", ".mjs"];
    for extension in extensions {
        const candidate = $"{relative}{extension}";
        if supported_entry(candidate, package_type) {
            const path = join2(root, candidate);
            const found = exists(path) catch (code) => false;
            if found {
                return path;
            }
        }
    }
    return none;
}

fn resolve_in(root: string, subpath: string): ?string {
    const manifest_path = join2(root, "package.json");
    const source = read_file(manifest_path) catch (code) {
        return none;
    };
    if source.len() > 256 * 1024 {
        return none;
    }
    const manifest = parse(source) catch (code) {
        return none;
    };
    if field(&manifest, "type") is kind {
        if kind == "commonjs" {
            return none;
        }
    }
    if entry_for(&manifest, subpath) is entry {
        return find_entry(root, entry, field(&manifest, "type"));
    }
    return none;
}

fn search_root(root: string, name: string, subpath: string): ?string {
    const package_root = join2(root, name);
    return resolve_in(package_root, subpath);
}

fn search_env_roots(name: string, subpath: string): ?string {
    if env_get("RUNTIME_PACKAGE_PATH") is roots {
        var start: usize = 0;
        const bytes = roots.bytes();
        var index: usize = 0;
        while index <= bytes.len() {
            if index == bytes.len() or bytes[index] == 58 {
                if index > start {
                    const root = roots.slice(start, index);
                    if search_root(root, name, subpath) is found {
                        return found;
                    }
                }
                start = index + 1;
            }
            index = index + 1;
        }
    }
    return none;
}

fn resolve(base: string, specifier: string): ?string {
    const name = package_name(specifier);
    if name.len() == 0 or name == "std" {
        return none;
    }
    var subpath = "";
    if name.len() < specifier.len() {
        subpath = specifier.slice(name.len() + 1, specifier.len());
    }
    if search_env_roots(name, subpath) is found {
        return found;
    }
    var directory = dirname(base);
    while directory.len() > 0 {
        const node_modules = join2(directory, "node_modules");
        if search_root(node_modules, name, subpath) is found {
            return found;
        }
        const parent = dirname(directory);
        if parent == directory {
            break;
        }
        directory = parent;
    }
    return none;
}

export c("hao_resolve_package") fn resolve_package(base_pointer: *const c_uchar, specifier_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    const base = text_from_c(base_pointer);
    const specifier = text_from_c(specifier_pointer);
    if resolve(base, specifier) is path {
        const bytes = path.bytes();
        if bytes.len() >= capacity as usize or bytes.len() > 4095 {
            return -1;
        }
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        return bytes.len() as c_int;
    }
    return -1;
}
