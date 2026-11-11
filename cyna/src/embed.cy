import { Runtime } from .runtime;
import { install_from } from .std;
import { copy_bytes } from .c_bytes;
import { Metric, MetricKind, MetricUnit, SpanKind, SpanStatus, root_context, int_attribute, Attribute } from std.telemetry;

extern c("hao_embed_bytes_valid") fn bytes_valid(pointer: *const c_uchar, length: c_size_t): c_int;
extern c("hao_embed_clear_error") fn clear_error(handle: c_size_t): void;
extern c("hao_embed_invalid_buffer") fn invalid_buffer(handle: c_size_t): void;
extern c("hao_embed_set_error") fn set_error(handle: c_size_t, message: *const c_uchar, length: c_size_t): void;

fn failure(handle: c_size_t, message: string): void {
    const bytes = message.bytes();
    set_error(handle, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
}

fn text(pointer: *const c_uchar, length: c_size_t): string {
    const bytes = copy_bytes(pointer, length as usize);
    return string.from(bytes[..]);
}

export c("hao_embed_abi_version") fn embed_abi_version(): c_uint {
    return 4 as c_uint;
}

// Internal embedding probe for the Cyna telemetry backend integration test.
export c("hao_embed_telemetry_probe") fn embed_telemetry_probe(handle: c_size_t): c_int {
    if handle == 0 { return 1; }
    const runtime = Runtime { handle: handle };
    const backend = runtime.telemetry();
    backend.add(Metric { group: "cyna.probe", name: "runs", kind: MetricKind.counter,
        unit: MetricUnit.count }, 3);
    const attributes: List<Attribute> = [int_attribute("step", 42)];
    const scope = backend.start_span(root_context(), "cyna.probe", SpanKind.internal, attributes.storage[..]);
    if scope.handle.id == 0 { return 1; }
    scope.event("cyna.event", attributes.storage[..]);
    scope.end(SpanStatus.ok);
    return 0;
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
    if handle == 0 {
        return 1;
    }
    if bytes_valid(source, source_len) == 0 or bytes_valid(filename, filename_len) == 0 {
        invalid_buffer(handle);
        return 1;
    }
    clear_error(handle);
    const runtime = Runtime { handle: handle };
    const status = runtime.eval(text(source, source_len), text(filename, filename_len));
    if status != 0 {
        failure(handle, "Module evaluation failed");
    }
    return status as c_int;
}

export c("hao_embed_run_until_idle") fn embed_run_until_idle(handle: c_size_t): c_int {
    if handle == 0 {
        return 1;
    }
    clear_error(handle);
    const runtime = Runtime { handle: handle };
    const status = runtime.run_until_idle();
    if status != 0 {
        failure(handle, "Event loop failed");
    }
    return status as c_int;
}

export c("hao_embed_register_module") fn embed_register_module(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int {
    if handle == 0 {
        return 1;
    }
    if bytes_valid(name, name_len) == 0 or bytes_valid(source, source_len) == 0 {
        invalid_buffer(handle);
        return 1;
    }
    clear_error(handle);
    const runtime = Runtime { handle: handle };
    const status = runtime.register_source_module(text(name, name_len), text(source, source_len));
    if status != 0 {
        failure(handle, "Module registration failed");
    }
    return status as c_int;
}

export c("hao_embed_install_std") fn embed_install_std(handle: c_size_t, directory: *const c_uchar, directory_len: c_size_t): c_int {
    if handle == 0 {
        return 1;
    }
    if bytes_valid(directory, directory_len) == 0 {
        invalid_buffer(handle);
        return 1;
    }
    clear_error(handle);
    const runtime = Runtime { handle: handle };
    const status = install_from(&runtime, text(directory, directory_len));
    if status != 0 {
        failure(handle, "Standard module installation failed");
    }
    return status as c_int;
}
