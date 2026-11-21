pub enum HaoReadError: i32 {
    not_found = 0,
    permission_denied,
    too_large,
    invalid_path,
    io_error,
}

extern {
    c("hao_bounded_read_length") fn hao_bounded_read_length(path: *const c_uchar, path_len: c_size_t,
        max_bytes: c_size_t
    ): c_llong;
    c("hao_bounded_read_into") fn hao_bounded_read_into(path: *const c_uchar, path_len: c_size_t,
        output: *c_uchar, size: c_size_t, exact: c_int
    ): c_int;
}

fn read(path: string, max_bytes: c_size_t, exact: bool): List<u8> !HaoReadError {
    const path_bytes = path.bytes();
    const native_length = hao_bounded_read_length(path_bytes.ptr as! *const c_uchar,
        path_bytes.len() as c_size_t, max_bytes
    );
    if native_length < 0 {
        if native_length == -1 {
            throw HaoReadError.not_found;
        }
        if native_length == -2 {
            throw HaoReadError.permission_denied;
        }
        if native_length == -3 {
            throw HaoReadError.too_large;
        }
        if native_length == -4 {
            throw HaoReadError.invalid_path;
        }
        throw HaoReadError.io_error;
    }
    const length = native_length as usize;
    var bytes: List<u8> = list<u8>();
    var index: usize = 0;
    while index < length {
        bytes.push(0);
        index = index + 1;
    }
    var exact_code: c_int = 0;
    if exact {
        exact_code = 1;
    }
    const status = hao_bounded_read_into(path_bytes.ptr as! *const c_uchar,
        path_bytes.len() as c_size_t, bytes.storage[..].ptr as! *c_uchar,
        length as c_size_t, exact_code
    );
    if status != 0 {
        if status == 1 {
            throw HaoReadError.not_found;
        }
        if status == 2 {
            throw HaoReadError.permission_denied;
        }
        if status == 3 {
            throw HaoReadError.too_large;
        }
        if status == 4 {
            throw HaoReadError.invalid_path;
        }
        throw HaoReadError.io_error;
    }
    return bytes;
}

pub fn read_bytes_limited(path: string, max_bytes: c_size_t): List<u8> !HaoReadError {
    return try read(path, max_bytes, false);
}

pub fn read_bytes_limited_exact(path: string, max_bytes: c_size_t): List<u8> !HaoReadError {
    return try read(path, max_bytes, true);
}
