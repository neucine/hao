import { exists, read_bytes, write_bytes } from std.fs;
import { copy_bytes, copy_output, text_from_c } from .c_bytes;

export c("hao_fs_exists") fn fs_exists(path_pointer: *const c_uchar): c_int {
    const path = text_from_c(path_pointer);
    const found = exists(path) catch (code) => false;
    if found {
        return 1;
    }
    return 0;
}

export c("hao_fs_read_into") fn fs_read_into(path_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    const path = text_from_c(path_pointer);
    const content = read_bytes(path) catch (code) {
        return -1;
    };
    if content.len() > capacity as usize {
        return -1;
    }
    const view = content[..];
    copy_output(output, view.ptr as! *const c_uchar, content.len() as c_size_t);
    return content.len() as c_int;
}

export c("hao_fs_write") fn fs_write(path_pointer: *const c_uchar, data_pointer: *const c_uchar, length: c_size_t): c_int {
    const path = text_from_c(path_pointer);
    const content = copy_bytes(data_pointer, length as usize);
    write_bytes(path, content[..]) catch (code) {
        return 1;
    };
    return 0;
}
