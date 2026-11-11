fn byte_at(source: *const c_uchar, index: usize): u8 {
    unchecked { return *(source + index) as u8; }
}

fn starts_with(source: *const c_uchar, start: usize, count: usize, prefix: string): bool {
    const bytes = prefix.bytes();
    if count < bytes.len() { return false; }
    var index: usize = 0;
    while index < bytes.len() {
        if byte_at(source, start + index) != bytes[index] { return false; }
        index = index + 1;
    }
    return true;
}

fn append(output: *c_uchar, capacity: usize, at: usize,
    source: *const c_uchar, start: usize, count: usize): usize {
    if at > capacity or count > capacity - at { return capacity + 1; }
    var index: usize = 0;
    while index < count {
        unchecked { *(output + at + index) = *(source + start + index); }
        index = index + 1;
    }
    return at + count;
}

fn append_text(output: *c_uchar, capacity: usize, at: usize, text: string): usize {
    const bytes = text.bytes();
    return append(output, capacity, at, bytes.ptr as! *const c_uchar, 0, bytes.len());
}

pub fn rewrite_declarations(source: *const c_uchar, length: usize,
    output: *c_uchar, capacity: usize): ?usize {
    var at: usize = 0;
    var line: usize = 0;
    while line < length {
        var end = line;
        while end < length and byte_at(source, end) != 10 { end = end + 1; }
        const count = end - line;
        if starts_with(source, line, count, "const ") {
            at = append_text(output, capacity, at, "var ");
            at = append(output, capacity, at, source, line + 6, count - 6);
        } else if starts_with(source, line, count, "let ") {
            at = append_text(output, capacity, at, "var ");
            at = append(output, capacity, at, source, line + 4, count - 4);
        } else if count >= 7 and starts_with(source, line, count, "class ") {
            var name_end: usize = 6;
            while name_end < count {
                const byte = byte_at(source, line + name_end);
                if byte == 32 or byte == 123 or byte == 9 { break; }
                name_end = name_end + 1;
            }
            if name_end > 6 {
                at = append_text(output, capacity, at, "var ");
                at = append(output, capacity, at, source, line + 6, name_end - 6);
                at = append_text(output, capacity, at, " = ");
            }
            at = append(output, capacity, at, source, line, count);
        } else {
            at = append(output, capacity, at, source, line, count);
        }
        if end < length {
            at = append_text(output, capacity, at, "\n");
        }
        line = end + 1;
    }
    if at > capacity { return none; }
    return at;
}

pub fn rewrite_cell_c(source: *const c_uchar,
    length: c_size_t, output: *c_uchar, capacity: c_size_t): c_size_t {
    const written = rewrite_declarations(source, length as usize, output, capacity as usize);
    if written is none { return capacity + 1; }
    return written as c_size_t;
}
