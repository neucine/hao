import { exists, read_bytes, write_bytes } from std.fs;

extern c("strlen") fn c_strlen(text: *const c_uchar): c_size_t;
extern c("hao_byte_at") fn byte_at(pointer: *const c_uchar, index: c_size_t): c_uchar;
extern c("hao_copy_bytes") fn copy_bytes(output: *c_uchar, input: *const c_uchar, length: c_size_t): void;

fn copy_c_bytes(pointer: *const c_uchar, length: usize): List<u8> {
    var bytes: List<u8> = list<u8>();
    var index: usize = 0;
    while index < length {
        bytes.push(byte_at(pointer, index as c_size_t) as u8);
        index = index + 1;
    }
    return bytes;
}

fn path_from_c(pointer: *const c_uchar): string {
    const bytes = copy_c_bytes(pointer, c_strlen(pointer) as usize);
    return string.from(bytes[..]);
}

export c("hao_fs_exists") fn fs_exists(path_pointer: *const c_uchar): c_int {
    const path = path_from_c(path_pointer);
    const found = exists(path) catch (code) => false;
    if found {
        return 1;
    }
    return 0;
}

export c("hao_fs_read_into") fn fs_read_into(path_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    const path = path_from_c(path_pointer);
    const content = read_bytes(path) catch (code) {
        return -1;
    };
    if content.len() > capacity as usize {
        return -1;
    }
    const view = content[..];
    copy_bytes(output, view.ptr as! *const c_uchar, content.len() as c_size_t);
    return content.len() as c_int;
}

export c("hao_fs_write") fn fs_write(path_pointer: *const c_uchar, data_pointer: *const c_uchar, length: c_size_t): c_int {
    const path = path_from_c(path_pointer);
    const content = copy_c_bytes(data_pointer, length as usize);
    write_bytes(path, content[..]) catch (code) {
        return 1;
    };
    return 0;
}
