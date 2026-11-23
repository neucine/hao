pub extern c("hao_runtime_new") fn runtime_new(stack_size: c_size_t, gc_threshold: c_size_t,
    thread_pool_size: c_size_t, trace_records: c_size_t, console_enabled: c_int
): c_size_t;
pub extern c("hao_runtime_free") fn runtime_free(handle: c_size_t): void;
pub extern c("hao_runtime_start_tests") fn runtime_start_tests(handle: c_size_t, grep: *const c_uchar, grep_len: c_size_t): c_int;
pub extern c("hao_runtime_test_failures") fn runtime_test_failures(handle: c_size_t): c_int;
pub extern c("hao_runtime_set_test_file_counts") fn runtime_set_test_file_counts(handle: c_size_t, loaded: c_size_t, failed: c_size_t, total: c_size_t): c_int;
pub extern c("hao_runtime_set_executable") fn runtime_set_executable(handle: c_size_t, path: *const c_uchar, path_len: c_size_t): c_int;
pub extern c("hao_runtime_eval_cell") fn runtime_eval_cell(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): ?*const c_uchar;
pub extern c("hao_runtime_free_text") fn runtime_free_text(text: *const c_uchar): void;
pub extern c("hao_runtime_drain_test") fn runtime_drain_test(handle: c_size_t, path: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_runtime_set_telemetry_console") fn runtime_set_telemetry_console(handle: c_size_t, enabled: c_int, port: c_ushort): void;
pub extern c("hao_runtime_set_native_stack_trace") fn runtime_set_native_stack_trace(handle: c_size_t, enabled: c_int): void;
pub extern c("hao_runtime_eval") fn runtime_eval(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
pub extern c("hao_runtime_eval_test") fn runtime_eval_test(handle: c_size_t, source: *const c_uchar, source_len: c_size_t, filename: *const c_uchar, filename_len: c_size_t): c_int;
pub extern c("hao_runtime_drain") fn runtime_drain(handle: c_size_t): c_int;
pub extern c("hao_runtime_run_turn") fn runtime_run_turn(handle: c_size_t): c_int;
pub extern c("hao_embed_bytes_valid") fn bytes_valid(pointer: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_embed_clear_error") fn clear_error(handle: c_size_t): void;
pub extern c("hao_embed_invalid_buffer") fn invalid_buffer(handle: c_size_t): void;
pub extern c("hao_embed_set_error") fn set_error(handle: c_size_t, message: *const c_uchar, length: c_size_t): void;

pub extern c("hao_runtime_register") fn runtime_register(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, source: *const c_uchar, source_len: c_size_t): c_int;
pub type NativeModuleLoader = c fn (*c_void, *const c_char): *c_void;
pub extern c("hao_runtime_register_native") fn runtime_register_native(handle: c_size_t, name: *const c_uchar, name_len: c_size_t, loader: NativeModuleLoader): c_int;

pub extern c("hao_global_install_console") fn install_console_native(handle: c_size_t): c_int;
pub extern c("hao_test_print_load") fn test_print_load(index: c_size_t, total: c_size_t, path: *const c_uchar, length: c_size_t): void;
pub extern c("hao_global_install_timer") fn install_timer_native(handle: c_size_t): c_int;
pub extern c("hao_error_eval") fn eval_source(context: *c_void, source: *const c_uchar, length: c_size_t): c_int;
pub extern c("hao_error_install_stack_capture") fn install_stack_capture(context: *c_void): void;

pub type Context = *c_void;
pub c struct JsValue {
    payload: c_llong;
    tag: c_llong;
}
pub fn tagged_value(payload: c_llong, tag: c_llong): JsValue {
    return JsValue {
        payload: payload,
        tag: tag
    };
}
pub fn value_tag(value: JsValue): c_llong {
    return value.tag;
}
pub type Callback = c fn (
    Context,
    JsValue,
    c_int,
    *const JsValue
): JsValue;
pub type Module = *c_void;
pub type ModuleInit = c fn (Context, Module): c_int;

pub extern c("JS_NewCModule") fn new_c_module(context: Context,
    name: *const c_char, initialize: ModuleInit
): Module;
pub extern c("JS_AddModuleExport") fn add_module_export(context: Context,
    module_ptr: Module, name: c_str
): c_int;
pub extern c("JS_SetModuleExport") fn set_module_export(context: Context,
    module_ptr: Module, name: c_str, value: JsValue
): c_int;
pub extern c("JS_NewCFunction2") fn new_c_function(context: Context,
    callback: Callback, name: c_str, length: c_int, kind: c_int,
    magic: c_int
): JsValue;
pub extern c("JS_NewObject") fn new_object(context: Context): JsValue;
pub extern c("JS_NewArray") fn new_array(context: Context): JsValue;
pub extern c("JS_NewNumber") fn new_number(context: Context,
    value: c_double
): JsValue;
pub extern c("hao_js_new_number_bits") fn new_number_bits(
    context: Context, bits: c_llong
): JsValue;
pub extern c("JS_NewStringLen") fn new_string_len(context: Context,
    value: *const c_char, length: c_size_t
): JsValue;
pub extern c("JS_NewArrayBufferCopy") fn new_array_buffer_copy(
    context: Context, value: *const c_uchar, length: c_size_t
): JsValue;
pub extern c("JS_NewTypeError") fn new_type_error(context: Context,
    message: c_str
): JsValue;
pub extern c("JS_NewError") fn new_error(context: Context): JsValue;
pub extern c("JS_Throw") fn throw_value(context: Context,
    value: JsValue
): JsValue;
pub extern c("JS_GetException") fn get_exception(context: Context): JsValue;
pub extern c("JS_SetPropertyStr") fn set_property_str(context: Context,
    object: JsValue, name: c_str, value: JsValue
): c_int;
pub extern c("JS_SetPropertyUint32") fn set_property_uint32(
    context: Context, object: JsValue, index: c_uint, value: JsValue
): c_int;
pub extern c("JS_GetPropertyStr") fn get_property_str(context: Context,
    object: JsValue, name: c_str
): JsValue;
pub extern c("JS_GetPropertyUint32") fn get_property_uint32(
    context: Context, object: JsValue, index: c_uint
): JsValue;
pub extern c("JS_NewAtomLen") fn new_atom_len(context: Context,
    value: *const c_char, length: c_size_t
): c_uint;
pub extern c("JS_SetProperty") fn set_property(context: Context,
    object: JsValue, property: c_uint, value: JsValue
): c_int;
pub extern c("JS_FreeAtom") fn free_atom(context: Context,
    atom: c_uint
): void;
pub extern c("JS_GetArrayBuffer") fn get_array_buffer(context: Context,
    length: *c_size_t, value: JsValue
): ?*c_uchar;
pub extern c("JS_IsArray") fn is_array(value: JsValue): c_int;
pub extern c("JS_ToInt64") fn to_int64(context: Context,
    output: *c_llong, value: JsValue
): c_int;
pub extern c("JS_ToFloat64") fn to_float64(context: Context,
    output: *c_double, value: JsValue
): c_int;
pub extern c("JS_ToCStringLen2") fn to_c_string_len(context: Context,
    length: *c_size_t, value: JsValue, cesu8: c_int
): ?*const c_char;
pub extern c("JS_FreeCString") fn free_c_string(context: Context,
    value: *const c_char
): void;
pub extern c("JS_FreeValue") fn free_value(context: Context,
    value: JsValue
): void;
pub extern c("JS_DupValue") fn dup_value(context: Context,
    value: JsValue
): JsValue;
