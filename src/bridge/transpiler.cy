// Rust transpiler C ABI. The QuickJS C bridge owns the current calls.
pub extern c("hao_transpile_types_for_path") fn transpile_types_for_path(
    source: *const c_uchar, source_path: *const c_uchar): ?*c_uchar;
pub extern c("hao_transform_module") fn transform_module(
    source: *const c_uchar, source_path: *const c_uchar,
    isolated: c_uchar, namespace_root: *const c_uchar): ?*c_uchar;
pub extern c("hao_transpiler_last_error") fn last_error(): ?*c_uchar;
pub extern c("hao_transpiler_free") fn free_text(text: *c_uchar): void;
