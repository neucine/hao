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
