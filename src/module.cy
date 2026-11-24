import { runtime_register as native_register } from .bridge.qjs;
import { cwd } from std.process;
import { copy_output, text_from_c } from .c_bytes;
import { allocate as runtime_alloc } from .runtime_allocator;

fn is_separator(byte: u8): bool {
    return byte == 47 or byte == 92;
}

fn is_ascii_letter(byte: u8): bool {
    return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122);
}

pub fn lexical_absolute(path: string): ?string {
    var input: List<u8> = list<u8>();
    const path_bytes = path.bytes();
    const has_drive = path_bytes.len() >= 3 and
        is_ascii_letter(path_bytes[0]) and path_bytes[1] == 58 and
        is_separator(path_bytes[2]);
    const is_absolute = path_bytes.len() > 0 and is_separator(path_bytes[0]);
    var output: List<u8> = list<u8>();
    var input_index: usize = 0;
    if has_drive {
        output.push(path_bytes[0]);
        output.push(58);
        output.push(47);
        input_index = 3;
    } else if not is_absolute {
        const directory = cwd() catch (code) {
            return none;
        };
        const directory_bytes = directory.bytes();
        const directory_drive = directory_bytes.len() >= 3 and
            is_ascii_letter(directory_bytes[0]) and directory_bytes[1] == 58 and
            is_separator(directory_bytes[2]);
        var directory_index: usize = 0;
        if directory_drive {
            output.push(directory_bytes[0]);
            output.push(58);
            output.push(47);
            directory_index = 3;
        } else {
            output.push(47);
        }
        while directory_index < directory_bytes.len() {
            if is_separator(directory_bytes[directory_index]) {
                input.push(47);
            } else {
                input.push(directory_bytes[directory_index]);
            }
            directory_index = directory_index + 1;
        }
        input.push(47);
    } else {
        output.push(47);
    }
    while input_index < path_bytes.len() {
        if is_separator(path_bytes[input_index]) {
            input.push(47);
        } else {
            input.push(path_bytes[input_index]);
        }
        input_index = input_index + 1;
    }

    var index: usize = 0;
    while index < input.len() {
        while index < input.len() and is_separator(input[index]) {
            index = index + 1;
        }
        const start = index;
        while index < input.len() and not is_separator(input[index]) {
            index = index + 1;
        }
        const length = index - start;
        if length == 0 or (length == 1 and input[start] == 46) {
            continue;
        }
        if length == 2 and input[start] == 46 and input[start + 1] == 46 {
            if output.len() > 1 {
                while output.len() > 1 and output[output.len() - 1] != 47 {
                    const removed = output.pop();
                }
                if output.len() > 1 {
                    const removed = output.pop();
                }
            }
            continue;
        }
        if output.len() > 0 and output[output.len() - 1] != 47 {
            output.push(47);
        }
        var position = start;
        while position < index {
            output.push(input[position]);
            position = position + 1;
        }
    }
    return string.from(output[..]);
}

pub fn lexical_absolute_c(path_pointer: *const c_uchar): ?*c_uchar {
    if path_pointer == (0 as! *const c_uchar) {
        return none;
    }
    const path = text_from_c(path_pointer);
    if lexical_absolute(path) is normalized {
        const bytes = normalized.bytes();
        const storage = runtime_alloc((bytes.len() + 1) as c_size_t);
        if storage == (0 as! *c_void) {
            return none;
        }
        const output = storage as! *c_uchar;
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        unchecked {
            *(output + bytes.len()) = 0;
        }
        return output;
    }
    return none;
}

pub fn relative_c(base_pointer: *const c_uchar,
    specifier_pointer: *const c_uchar
): ?*c_uchar {
    if base_pointer == (0 as! *const c_uchar) or
    specifier_pointer == (0 as! *const c_uchar) {
        return none;
    }
    const base = text_from_c(base_pointer);
    const specifier = text_from_c(specifier_pointer);
    const base_bytes = base.bytes();
    var directory_end: usize = 0;
    var found_slash = false;
    var index: usize = 0;
    while index < base_bytes.len() {
        if base_bytes[index] == 47 {
            directory_end = index;
            found_slash = true;
        }
        index = index + 1;
    }
    var joined: List<u8> = list<u8>();
    if found_slash {
        for byte in base_bytes[0..directory_end] {
            joined.push(byte);
        }
    } else {
        joined.push(46);
    }
    joined.push(47);
    for byte in specifier.bytes() {
        joined.push(byte);
    }
    if lexical_absolute(string.from(joined[..])) is normalized {
        const bytes = normalized.bytes();
        const storage = runtime_alloc((bytes.len() + 1) as c_size_t);
        if storage == (0 as! *c_void) {
            return none;
        }
        const output = storage as! *c_uchar;
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        unchecked {
            *(output + bytes.len()) = 0;
        }
        return output;
    }
    return none;
}

pub fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t,
    source: *const c_uchar, source_len: c_size_t
): c_int {
    return native_register(handle, name, name_len, source, source_len);
}
