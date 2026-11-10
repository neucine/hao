extern c("strlen") fn c_strlen(text: *const c_uchar): c_size_t;
extern c("hao_byte_at") fn byte_at(pointer: *const c_uchar, index: c_size_t): c_uchar;
pub extern c("hao_copy_bytes") fn copy_output(output: *c_uchar, input: *const c_uchar, length: c_size_t): void;

pub fn copy_bytes(pointer: *const c_uchar, length: usize): List<u8> {
    var bytes: List<u8> = list<u8>();
    var index: usize = 0;
    while index < length {
        bytes.push(byte_at(pointer, index as c_size_t) as u8);
        index = index + 1;
    }
    return bytes;
}

pub fn text_from_c(pointer: *const c_uchar): string {
    const bytes = copy_bytes(pointer, c_strlen(pointer) as usize);
    return string.from(bytes[..]);
}
