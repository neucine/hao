import { copy_output, text_from_c } from .c_bytes;
import { allocate as runtime_alloc } from .runtime_allocator;

pub fn valid_method(method: string): bool {
    return method == "GET" or method == "HEAD" or method == "POST" or
        method == "PUT" or method == "DELETE" or method == "CONNECT" or
        method == "OPTIONS" or method == "TRACE" or method == "PATCH" or
        method == "QUERY";
}

pub fn url_error(url: string): i32 {
    const bytes = url.bytes();
    var colon: usize = 0;
    while colon < bytes.len() and bytes[colon] != 58 { colon = colon + 1; }
    if colon == bytes.len() { return 1; } // InvalidFormat
    if colon == 0 { return 2; } // UnexpectedCharacter
    const first = bytes[0];
    if not ((first >= 65 and first <= 90) or (first >= 97 and first <= 122)) { return 2; }
    var index: usize = 1;
    while index < colon {
        const byte = bytes[index];
        if not ((byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or
            (byte >= 48 and byte <= 57) or byte == 43 or byte == 45 or byte == 46) { return 2; }
        index = index + 1;
    }
    const scheme = url.slice(0, colon);
    if scheme != "http" and scheme != "https" { return 3; } // UnsupportedUriScheme
    if colon + 2 >= bytes.len() or bytes[colon + 1] != 47 or bytes[colon + 2] != 47 { return 4; } // UriMissingHost
    const start = colon + 3;
    var end = start;
    while end < bytes.len() and bytes[end] != 47 and bytes[end] != 63 and bytes[end] != 35 {
        end = end + 1;
    }
    if end == start { if end < bytes.len() and bytes[end] == 47 { return 4; } return 1; }
    const authority = url.slice(start, end);
    const parts = authority.bytes();
    var host_start: usize = 0;
    index = 0;
    while index < parts.len() {
        if parts[index] == 64 { host_start = index + 1; }
        index = index + 1;
    }
    if host_start == parts.len() { return 4; }
    if parts[host_start] == 93 { return 1; }
    if parts[host_start] == 91 {
        var close = host_start + 1;
        while close < parts.len() and parts[close] != 93 { close = close + 1; }
        if close == parts.len() { return 1; }
        return 6; // InvalidHostName at the current host boundary
    }
    var host_end = parts.len();
    index = host_start;
    while index < parts.len() {
        if parts[index] == 58 { host_end = index; }
        index = index + 1;
    }
    if host_end == host_start { return 1; }
    index = host_start;
    while index < host_end {
        const byte = parts[index];
        if byte <= 32 or byte == 127 or byte == 91 or byte == 93 or byte == 58 { return 6; }
        index = index + 1;
    }
    if host_end < parts.len() {
        var port_start = host_end + 1;
        if port_start < parts.len() and parts[port_start] == 43 { port_start = port_start + 1; }
        if port_start == parts.len() { return 5; }
        var port: usize = 0;
        index = port_start;
        while index < parts.len() {
            const byte = parts[index];
            if byte < 48 or byte > 57 { return 5; }
            port = port * 10 + (byte - 48) as usize;
            if port > 65535 { return 5; }
            index = index + 1;
        }
    }
    return 0;
}

pub fn transport_url(url: string): string {
    const bytes = url.bytes();
    var authority_start: usize = 0;
    while authority_start + 2 < bytes.len() {
        if bytes[authority_start] == 58 and bytes[authority_start + 1] == 47 and bytes[authority_start + 2] == 47 {
            authority_start = authority_start + 3;
            break;
        }
        authority_start = authority_start + 1;
    }
    var end = authority_start;
    var host_start = authority_start;
    while end < bytes.len() and bytes[end] != 47 and bytes[end] != 63 and bytes[end] != 35 {
        if bytes[end] == 64 { host_start = end + 1; }
        end = end + 1;
    }
    var index = host_start;
    while index + 1 < end {
        if bytes[index] == 58 and bytes[index + 1] == 43 {
            const prefix = url.slice(0, index + 1);
            const suffix = url.slice(index + 2, url.len());
            return $"{prefix}{suffix}";
        }
        index = index + 1;
    }
    return url.clone();
}

pub fn valid_method_c(method: *const c_uchar): c_int {
    if method == (0 as! *const c_uchar) { return 0; }
    if valid_method(text_from_c(method)) { return 1; }
    return 0;
}

pub fn url_error_c(url: *const c_uchar): c_int {
    if url == (0 as! *const c_uchar) { return 1; }
    return url_error(text_from_c(url)) as c_int;
}

pub fn transport_url_c(url: *const c_uchar): ?*c_uchar {
    if url == (0 as! *const c_uchar) { return none; }
    const value = transport_url(text_from_c(url));
    const bytes = value.bytes();
    const storage = runtime_alloc((bytes.len() + 1) as c_size_t);
    if storage == (0 as! *c_void) { return none; }
    const output = storage as! *c_uchar;
    copy_output(output, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
    unchecked { *(output + bytes.len()) = 0; }
    return output;
}
