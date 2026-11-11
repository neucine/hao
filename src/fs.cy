import { FsError, read_bytes_limited, create_dir, exists } from std.fs;
import { dirname } from std.path;


pub fn read_file_limited(path: string, max_bytes: usize): ?string {
    const bytes = path.bytes();
    for byte in bytes {
        if byte == 0 { return none; }
    }
    const content = read_bytes_limited(path, max_bytes as c_size_t) catch (code) { return none; };
    return string.from(content[..]);
}

pub fn script_read_error(path: string, limit: usize): i32 {
    const bytes = path.bytes();
    if bytes.len() > 1024 { return 2; }
    for byte in bytes {
        if byte == 0 { return 2; }
    }
    var component: usize = 0;
    for byte in bytes {
        if byte == 47 { component = 0; } else {
            component = component + 1;
            if component > 255 { return 0; }
        }
    }
    const result = read_bytes_limited(path, limit as c_size_t) catch (code) {
        if code == FsError.too_large { return 1; }
        if code == FsError.not_found or code == FsError.permission_denied or code == FsError.invalid_path { return 0; }
        return 3;
    };
    const ignored = result;
    return 4;
}

pub fn make_path(path: string): i32 {
    const found = exists(path.clone()) catch (code) => false;
    if found { return 0; }
    const parent = dirname(path.clone());
    if parent == path or parent.len() == 0 { return 1; }
    if make_path(parent) != 0 { return 1; }
    create_dir(path.clone()) catch (code) {
        const created = exists(path) catch (other) => false;
        if not created { return 1; }
    };
    return 0;
}
