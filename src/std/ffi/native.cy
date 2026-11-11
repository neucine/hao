import { text_from_c } from .c_bytes;

pub fn type_code(name: string): i32 {
    return switch name {
        "void" => 0; "bool" => 1;
        "i8" => 2; "i16" => 3; "i32" => 4; "i64" => 5;
        "u8" => 6; "u16" => 7; "u32" => 8; "u64" => 9;
        "f32" => 10; "f64" => 11;
        "ptr" => 12; "cstring" => 13; "buffer" => 14;
        _ => -1;
    };
}

export c("hao_ffi_type_code") fn type_code_c(name: *const c_uchar): c_int {
    return type_code(text_from_c(name)) as c_int;
}

pub fn parse_unsigned(text: *const c_uchar, byte_length: usize): ?u64 {
    var length = byte_length;
    while length > 0 {
        var last: c_uchar = 0;
        unchecked { last = *(text + (length - 1)); }
        if last != 110 { break; }
        length = length - 1;
    }
    if length == 0 { return none; }
    const limit: u64 = 18446744073709551615;
    var value: u64 = 0;
    var index: usize = 0;
    while index < length {
        var byte: c_uchar = 0;
        unchecked { byte = *(text + index); }
        if byte < 48 or byte > 57 { return none; }
        const digit = (byte - 48) as u64;
        if value > (limit - digit) / 10 { return none; }
        value = value * 10 + digit;
        index = index + 1;
    }
    return value;
}

export c("hao_ffi_parse_unsigned") fn parse_unsigned_c(text: *const c_uchar,
    length: c_size_t, output: *u64): c_int {
    const value = parse_unsigned(text, length as usize);
    if value is none { return 0; }
    unchecked { *output = value; }
    return 1;
}
