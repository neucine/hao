// The sole Cyna export surface for Hao. Feature modules own behavior.
import { RunResult } from .bridge.host;
import { new_loop as impl_async_uv_new } from .async.uv;
import { free_loop as impl_async_uv_free } from .async.uv;
import { run_once as impl_async_uv_run_once } from .async.uv;
import { run_nowait as impl_async_uv_run_nowait } from .async.uv;
import { embed_abi_version as impl_embed_abi_version } from .embed;
import { embed_telemetry_probe as impl_embed_telemetry_probe } from .embed;
import { embed_new as impl_embed_new } from .embed;
import { embed_free as impl_embed_free } from .embed;
import { embed_eval as impl_embed_eval } from .embed;
import { embed_run_until_idle as impl_embed_run_until_idle } from .embed;
import { embed_register_module as impl_embed_register_module } from .embed;
import { embed_install_std as impl_embed_install_std } from .embed;
import { install_runtime_error as impl_install_runtime_error } from .errors;
import { addon_name_length as impl_addon_name_length } from .js.addon;
import { addon_write_name as impl_addon_write_name } from .js.addon;
import { rewrite_cell_c as impl_jupyter_rewrite_cell } from .jupyter.cell;
import { resolve_package as impl_resolve_package } from .package;
import { snapshot_c as impl_process_memory_snapshot } from .process_memory;
import { type_code_c as impl_ffi_type_code } from .std.ffi.native;
import { parse_unsigned_c as impl_ffi_parse_unsigned } from .std.ffi.native;
import { fs_read_alloc as impl_fs_read_alloc } from .std.fs.native;
import { fs_exists as impl_fs_exists } from .std.fs.native;
import { fs_write as impl_fs_write } from .std.fs.native;
import { valid_method_c as impl_http_valid_method } from .std.http.native;
import { url_error_c as impl_http_url_error } from .std.http.native;
import { transport_url_c as impl_http_transport_url } from .std.http.native;
import { limits_error_c as impl_http_server_limits_error } from .std.http.server_uv;
import { run_json as impl_process_run_json } from .std.process.native;
import { text_valid as impl_metric_text_valid } from .telemetry.metrics;
import { metric_kind as impl_metric_kind } from .telemetry.metrics;
import { definition_valid as impl_metric_definition_valid } from .telemetry.metrics;
import { can_add as impl_metric_can_add } from .telemetry.metrics;
import { can_set as impl_metric_can_set } from .telemetry.metrics;
import { can_observe as impl_metric_can_observe } from .telemetry.metrics;

export c("hao_async_uv_new") fn abi_async_uv_new(): *c_void {
    return impl_async_uv_new();
}

export c("hao_async_uv_free") fn abi_async_uv_free(loop: *c_void): void {
    impl_async_uv_free(loop);
}

export c("hao_async_uv_run_once") fn abi_async_uv_run_once(loop: *c_void): c_int {
    return impl_async_uv_run_once(loop);
}

export c("hao_async_uv_run_nowait") fn abi_async_uv_run_nowait(loop: *c_void): c_int {
    return impl_async_uv_run_nowait(loop);
}

export c("hao_embed_abi_version") fn abi_embed_abi_version(): c_uint {
    return impl_embed_abi_version();
}

export c("hao_embed_telemetry_probe") fn abi_embed_telemetry_probe(handle: c_size_t): c_int {
    return impl_embed_telemetry_probe(handle);
}

export c("hao_embed_new") fn abi_embed_new(): c_size_t {
    return impl_embed_new();
}

export c("hao_embed_free") fn abi_embed_free(handle: c_size_t): void {
    impl_embed_free(handle);
}

export c("hao_embed_eval") fn abi_embed_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int {
    return impl_embed_eval(handle, source, source_len, filename, filename_len);
}

export c("hao_embed_run_until_idle") fn abi_embed_run_until_idle(handle: c_size_t): c_int {
    return impl_embed_run_until_idle(handle);
}

export c("hao_embed_register_module") fn abi_embed_register_module(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int {
    return impl_embed_register_module(handle, name, name_len, source, source_len);
}

export c("hao_embed_install_std") fn abi_embed_install_std(handle: c_size_t, directory: *const c_uchar, directory_len: c_size_t): c_int {
    return impl_embed_install_std(handle, directory, directory_len);
}

export c("hao_install_runtime_error") fn abi_install_runtime_error(context: *c_void): c_int {
    return impl_install_runtime_error(context);
}

export c("hao_addon_name_length") fn abi_addon_name_length(specifier: *const c_uchar, path: *const c_uchar): c_size_t {
    return impl_addon_name_length(specifier, path);
}

export c("hao_addon_write_name") fn abi_addon_write_name(specifier: *const c_uchar, path: *const c_uchar,
    output: *c_uchar, capacity: c_size_t): c_int {
    return impl_addon_write_name(specifier, path, output, capacity);
}

export c("hao_jupyter_rewrite_cell") fn abi_jupyter_rewrite_cell(source: *const c_uchar,
    length: c_size_t, output: *c_uchar, capacity: c_size_t): c_size_t {
    return impl_jupyter_rewrite_cell(source, length, output, capacity);
}

export c("hao_resolve_package") fn abi_resolve_package(base_pointer: *const c_uchar, specifier_pointer: *const c_uchar, output: *c_uchar, capacity: c_size_t): c_int {
    return impl_resolve_package(base_pointer, specifier_pointer, output, capacity);
}

export c("hao_process_memory_snapshot") fn abi_process_memory_snapshot(resident: *c_ullong, footprint: *c_ullong): void {
    impl_process_memory_snapshot(resident, footprint);
}

export c("hao_ffi_type_code") fn abi_ffi_type_code(name: *const c_uchar): c_int {
    return impl_ffi_type_code(name);
}

export c("hao_ffi_parse_unsigned") fn abi_ffi_parse_unsigned(text: *const c_uchar,
    length: c_size_t, output: *c_ullong): c_int {
    return impl_ffi_parse_unsigned(text, length, output);
}

export c("hao_fs_read_alloc") fn abi_fs_read_alloc(path_pointer: *const c_uchar,
    path_length: c_size_t, limit: c_size_t): ?*c_uchar {
    return impl_fs_read_alloc(path_pointer, path_length, limit);
}

export c("hao_fs_exists") fn abi_fs_exists(path_pointer: *const c_uchar): c_int {
    return impl_fs_exists(path_pointer);
}

export c("hao_fs_write") fn abi_fs_write(path_pointer: *const c_uchar, data_pointer: *const c_uchar, length: c_size_t): c_int {
    return impl_fs_write(path_pointer, data_pointer, length);
}

export c("hao_http_valid_method") fn abi_http_valid_method(method: *const c_uchar): c_int {
    return impl_http_valid_method(method);
}

export c("hao_http_url_error") fn abi_http_url_error(url: *const c_uchar): c_int {
    return impl_http_url_error(url);
}

export c("hao_http_transport_url") fn abi_http_transport_url(url: *const c_uchar): ?*c_uchar {
    return impl_http_transport_url(url);
}

export c("hao_http_server_limits_error") fn abi_http_server_limits_error(port: c_double,
    max_connections: c_double, timeout_ms: c_double): c_int {
    return impl_http_server_limits_error(port, max_connections, timeout_ms);
}

export c("hao_process_run_json") fn abi_process_run_json(options_pointer: *const c_uchar, options_len: c_size_t, stdout_output: *c_uchar, stderr_output: *c_uchar, capacity: c_size_t, result: *RunResult): c_int {
    return impl_process_run_json(options_pointer, options_len, stdout_output, stderr_output, capacity, result);
}

export c("hao_metric_text_valid") fn abi_metric_text_valid(pointer: *const c_uchar, length: c_size_t, required: c_int): c_int {
    return impl_metric_text_valid(pointer, length, required);
}

export c("hao_metric_kind") fn abi_metric_kind(name: *const c_uchar): c_uint {
    return impl_metric_kind(name);
}

export c("hao_metric_definition_valid") fn abi_metric_definition_valid(scope: *const c_uchar,
    name: *const c_uchar, kind: c_uint, unit: *const c_uchar): c_int {
    return impl_metric_definition_valid(scope, name, kind, unit);
}

export c("hao_metric_can_add") fn abi_metric_can_add(kind: c_uint, delta: c_double): c_int {
    return impl_metric_can_add(kind, delta);
}

export c("hao_metric_can_set") fn abi_metric_can_set(kind: c_uint, value: c_double): c_int {
    return impl_metric_can_set(kind, value);
}

export c("hao_metric_can_observe") fn abi_metric_can_observe(kind: c_uint): c_int {
    return impl_metric_can_observe(kind);
}
