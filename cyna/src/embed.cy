import { Runtime } from .runtime;
import { install_from } from .std_modules;
import { copy_bytes } from .c_bytes;

extern c("hao_embed_bytes_valid") fn bytes_valid(pointer: *const c_uchar, length: c_size_t): c_int;

fn text(pointer: *const c_uchar, length: c_size_t): string {
    const bytes = copy_bytes(pointer, length as usize);
    return string.from(bytes[..]);
}

export c("hao_embed_abi_version") fn embed_abi_version(): c_uint {
    return 1 as c_uint;
}

export c("hao_embed_new") fn embed_new(): c_size_t {
    if Runtime.init() is runtime {
        return runtime.handle;
    }
    return 0;
}

export c("hao_embed_free") fn embed_free(handle: c_size_t): void {
    if handle != 0 {
        const runtime = Runtime { handle: handle };
        runtime.deinit();
    }
}

export c("hao_embed_eval") fn embed_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int {
    if handle == 0 or bytes_valid(source, source_len) == 0 or bytes_valid(filename, filename_len) == 0 {
        return 1;
    }
    const runtime = Runtime { handle: handle };
    return runtime.eval(text(source, source_len), text(filename, filename_len)) as c_int;
}

export c("hao_embed_run_until_idle") fn embed_run_until_idle(handle: c_size_t): c_int {
    if handle == 0 {
        return 1;
    }
    const runtime = Runtime { handle: handle };
    return runtime.run_until_idle() as c_int;
}

export c("hao_embed_register_module") fn embed_register_module(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int {
    if handle == 0 or bytes_valid(name, name_len) == 0 or bytes_valid(source, source_len) == 0 {
        return 1;
    }
    const runtime = Runtime { handle: handle };
    return runtime.register_source_module(text(name, name_len), text(source, source_len)) as c_int;
}

export c("hao_embed_install_std") fn embed_install_std(handle: c_size_t, directory: *const c_uchar, directory_len: c_size_t): c_int {
    if handle == 0 or bytes_valid(directory, directory_len) == 0 {
        return 1;
    }
    const runtime = Runtime { handle: handle };
    return install_from(&runtime, text(directory, directory_len)) as c_int;
}
