import { copy_output, text_from_c } from .c_bytes;

pub fn is_addon_path(path: string): bool {
    return path.ends_with(".dylib") or path.ends_with(".so") or
        path.ends_with(".dll") or path.ends_with(".node");
}

pub fn normalized_name(specifier: string, path: string): string {
    if is_addon_path(path) { return $"addon:{specifier}\n{path}"; }
    return path.clone();
}

pub fn addon_name_length(specifier: *const c_uchar, path: *const c_uchar): c_size_t {
    return normalized_name(text_from_c(specifier), text_from_c(path)).len() as c_size_t;
}

pub fn addon_write_name(specifier: *const c_uchar, path: *const c_uchar,
    output: *c_uchar, capacity: c_size_t): c_int {
    const name = normalized_name(text_from_c(specifier), text_from_c(path));
    const bytes = name.bytes();
    if output == (0 as! *c_uchar) or capacity <= bytes.len() as c_size_t { return 1; }
    copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
    unchecked { *(output + bytes.len()) = 0; }
    return 0;
}
