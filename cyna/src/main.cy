import { args } from std.process;
import { read_file } from std.fs;

extern c("hao_eval") fn hao_eval(source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;

fn main(): i32 {
    const arguments = args();
    if arguments.len() != 2 {
        println("Usage: hao <file.js>");
        return 2;
    }
    const path = arguments[1];
    if path == "--version" or path == "-v" {
        println("hao 0.1.2 (Cyna runtime preview)");
        return 0;
    }
    const source = read_file(path) catch (code) {
        println("Unable to read script");
        return 1;
    };
    const source_bytes = source.bytes();
    const path_bytes = path.bytes();
    return hao_eval(source_bytes.ptr as! *const c_uchar, source_bytes.len() as c_size_t, path_bytes.ptr as! *const c_uchar, path_bytes.len() as c_size_t) as i32;
}
