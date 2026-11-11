extern c("strlen") fn c_strlen(text: *const c_uchar): c_size_t;
fn byte_at(pointer: *const c_uchar, index: usize): c_uchar {
    unchecked { return *(pointer + index); }
}

pub fn copy_output(output: *c_uchar, input: *const c_uchar, length: c_size_t): void {
    var index: usize = 0;
    while index < length as usize {
        unchecked { *(output + index) = *(input + index); }
        index = index + 1;
    }
}

pub fn copy_bytes(pointer: *const c_uchar, length: usize): List<u8> {
    var bytes: List<u8> = list<u8>();
    var index: usize = 0;
    while index < length {
        bytes.push(byte_at(pointer, index) as u8);
        index = index + 1;
    }
    return bytes;
}

pub fn text_from_c(pointer: *const c_uchar): string {
    const bytes = copy_bytes(pointer, c_strlen(pointer) as usize);
    return string.from(bytes[..]);
}
