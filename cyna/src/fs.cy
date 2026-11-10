import { exists, write_bytes } from std.fs;
import { copy_bytes, text_from_c } from .c_bytes;
import { read_alloc_limited, buffer_length, free_buffer } from .fs_limit;

pub fn read_file_limited(path: string, max_bytes: usize): ?string {
    const bytes = path.bytes();
    if read_alloc_limited(bytes.ptr as! *const c_uchar, bytes.len() as c_size_t,
        max_bytes as c_size_t) is content {
        defer free_buffer(content);
        const length = buffer_length(content as! *const c_uchar);
        const source = copy_bytes(content as! *const c_uchar, length as usize);
        return string.from(source[..]);
    }
    return none;
}

export c("hao_fs_exists") fn fs_exists(path_pointer: *const c_uchar): c_int {
    const path = text_from_c(path_pointer);
    const found = exists(path) catch (code) => false;
    if found {
        return 1;
    }
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
