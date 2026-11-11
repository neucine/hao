import { exists, read_bytes_limited, write_bytes } from std.fs;
import { copy_bytes, copy_output, text_from_c } from .c_bytes;
import { allocate as runtime_alloc } from .runtime_allocator;


pub fn read_file_limited(path: string, max_bytes: usize): ?string {
    const bytes = path.bytes();
    for byte in bytes {
        if byte == 0 { return none; }
    }
    const content = read_bytes_limited(path, max_bytes as c_size_t) catch (code) { return none; };
    return string.from(content[..]);
}

export c("hao_fs_read_alloc") fn fs_read_alloc(path_pointer: *const c_uchar,
    path_length: c_size_t, limit: c_size_t): ?*c_uchar {
    if path_pointer == (0 as! *const c_uchar) { return none; }
    const path_bytes = copy_bytes(path_pointer, path_length as usize);
    const path = string.from(path_bytes[..]);
    const content = read_bytes_limited(path, limit) catch (code) { return none; };
    const view = content[..];
    const storage = runtime_alloc((view.len() + 1) as c_size_t);
    if storage == (0 as! *c_void) { return none; }
    const output = storage as! *c_uchar;
    copy_output(output, view.ptr as! *const c_uchar, view.len() as c_size_t);
    unchecked { *(output + view.len()) = 0; }
    return output;
}

export c("hao_fs_exists") fn fs_exists(path_pointer: *const c_uchar): c_int {
    if path_pointer == (0 as! *const c_uchar) { return 0; }
    const present = exists(text_from_c(path_pointer)) catch (code) => false;
    if present { return 1; }
    return 0;
}

export c("hao_fs_write") fn fs_write(path_pointer: *const c_uchar, data_pointer: *const c_uchar, length: c_size_t): c_int {
    const path = text_from_c(path_pointer);
    const content = copy_bytes(data_pointer, length as usize);
    write_bytes(path, content[..]) catch (code) {
        return 1;
    };
    return 0;
}
