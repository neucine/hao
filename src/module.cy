import { runtime_register as native_register } from .bridge.qjs;
import { cwd } from std.process;
import { copy_output, text_from_c } from .c_bytes;
import { allocate as runtime_alloc } from .runtime_allocator;

pub fn lexical_absolute(path: string): ?string {
    var input: List<u8> = list<u8>();
    const path_bytes = path.bytes();
    if path_bytes.len() == 0 or path_bytes[0] != 47 {
        const directory = cwd() catch (code) { return none; };
        for byte in directory.bytes() { input.push(byte); }
        input.push(47);
    }
    for byte in path_bytes { input.push(byte); }

    var output: List<u8> = list<u8>();
    output.push(47);
    var index: usize = 0;
    while index < input.len() {
        while index < input.len() and input[index] == 47 { index = index + 1; }
        const start = index;
        while index < input.len() and input[index] != 47 { index = index + 1; }
        const length = index - start;
        if length == 0 or (length == 1 and input[start] == 46) { continue; }
        if length == 2 and input[start] == 46 and input[start + 1] == 46 {
            if output.len() > 1 {
                while output.len() > 1 and output[output.len() - 1] != 47 {
                    const removed = output.pop();
                }
                if output.len() > 1 { const removed = output.pop(); }
            }
            continue;
        }
        if output.len() > 1 { output.push(47); }
        var position = start;
        while position < index {
            output.push(input[position]);
            position = position + 1;
        }
    }
    return string.from(output[..]);
}

pub fn lexical_absolute_c(path_pointer: *const c_uchar): ?*c_uchar {
    if path_pointer == (0 as! *const c_uchar) { return none; }
    const path = text_from_c(path_pointer);
    if lexical_absolute(path) is normalized {
        const bytes = normalized.bytes();
        const storage = runtime_alloc((bytes.len() + 1) as c_size_t);
        if storage == (0 as! *c_void) { return none; }
        const output = storage as! *c_uchar;
        copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
        unchecked { *(output + bytes.len()) = 0; }
        return output;
    }
    return none;
}

pub fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t,
    source: *const c_uchar, source_len: c_size_t): c_int {
    return native_register(handle, name, name_len, source, source_len);
}
