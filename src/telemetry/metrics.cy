import { copy_bytes, text_from_c } from .c_bytes;

fn valid_text(value: string, required: bool): bool {
    const bytes = value.bytes();
    if required and bytes.len() == 0 { return false; }
    for byte in bytes {
        if byte == 0 or byte == 10 or byte == 13 { return false; }
    }
    return true;
}

pub fn text_valid(pointer: *const c_uchar, length: c_size_t, required: c_int): c_int {
    if pointer == (0 as! *const c_uchar) { return 0; }
    const bytes = copy_bytes(pointer, length as usize);
    if valid_text(string.from(bytes[..]), required != 0) { return 1; }
    return 0;
}

pub fn metric_kind(name: *const c_uchar): c_uint {
    if name == (0 as! *const c_uchar) { return 0; }
    const value = text_from_c(name);
    if value == "counter" { return 1; }
    if value == "gauge" { return 2; }
    if value == "histogram" { return 3; }
    return 0;
}

pub fn definition_valid(scope: *const c_uchar,
    name: *const c_uchar, kind: c_uint, unit: *const c_uchar): c_int {
    if scope == (0 as! *const c_uchar) or name == (0 as! *const c_uchar) { return 0; }
    if kind < 1 or kind > 3 { return 0; }
    if not valid_text(text_from_c(scope), true) or not valid_text(text_from_c(name), true) { return 0; }
    if unit != (0 as! *const c_uchar) and not valid_text(text_from_c(unit), false) { return 0; }
    return 1;
}

pub fn can_add(kind: c_uint, delta: c_double): c_int {
    if kind == 3 or (kind == 1 and delta < 0) { return 0; }
    return 1;
}

pub fn can_set(kind: c_uint, value: c_double): c_int {
    if kind != 2 { return 0; }
    return 1;
}

pub fn can_observe(kind: c_uint): c_int {
    if kind != 3 { return 0; }
    return 1;
}
