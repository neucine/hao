// Public JavaScript value and native-module API for Cyna hosts.
//
// QuickJS is an implementation detail of Hao. Hosts use these context,
// value, callback, and module operations without declaring JS_* symbols or
// depending on QuickJS's JSValue layout.
import .bridge.qjs as bridge;

pub type Context = bridge.Context;
pub type JsValue = bridge.JsValue;
pub type Callback = bridge.Callback;
pub type Module = bridge.Module;
pub type ModuleInit = bridge.ModuleInit;

const tag_bool: c_llong = 1;
const tag_undefined: c_llong = 3;
const tag_exception: c_llong = 6;

pub fn undefined(): JsValue {
    return bridge.tagged_value(0, tag_undefined);
}

pub fn bool(context: Context, value: bool): JsValue {
    var payload: c_llong = 0;
    if value {
        payload = 1;
    }
    return bridge.tagged_value(payload, tag_bool);
}

pub fn is_undefined(value: JsValue): bool {
    return bridge.value_tag(value) == tag_undefined;
}

pub fn is_exception(value: JsValue): bool {
    return bridge.value_tag(value) == tag_exception;
}

pub fn new_module(context: Context, name: *const c_char,
    initialize: ModuleInit
): Module {
    return bridge.new_c_module(context, name, initialize);
}

pub fn add_module_export(context: Context, module_ptr: Module,
    name: c_str
): c_int {
    return bridge.add_module_export(context, module_ptr, name);
}

pub fn set_module_export(context: Context, module_ptr: Module, name: c_str,
    value: JsValue
): c_int {
    return bridge.set_module_export(context, module_ptr, name, value);
}

pub fn new_function(context: Context, callback: Callback, name: c_str,
    length: c_int, kind: c_int, magic: c_int
): JsValue {
    return bridge.new_c_function(
        context, callback, name, length, kind, magic
    );
}

pub fn new_object(context: Context): JsValue {
    return bridge.new_object(context);
}

pub fn new_array(context: Context): JsValue {
    return bridge.new_array(context);
}

pub fn new_number(context: Context, value: f64): JsValue {
    const bits = value as! c_llong;
    return bridge.new_number_bits(context, bits);
}

pub fn new_string_len(context: Context, value: *const c_char,
    length: c_size_t
): JsValue {
    return bridge.new_string_len(context, value, length);
}

pub fn new_array_buffer_copy(context: Context, value: *const c_uchar,
    length: c_size_t
): JsValue {
    return bridge.new_array_buffer_copy(context, value, length);
}

pub fn new_type_error(context: Context, message: c_str): JsValue {
    return bridge.new_type_error(context, message);
}

pub fn new_error(context: Context): JsValue {
    return bridge.new_error(context);
}

pub fn throw_value(context: Context, value: JsValue): JsValue {
    return bridge.throw_value(context, value);
}

pub fn get_exception(context: Context): JsValue {
    return bridge.get_exception(context);
}

pub fn set_property_str(context: Context, object: JsValue, name: c_str,
    value: JsValue
): c_int {
    return bridge.set_property_str(context, object, name, value);
}

pub fn set_property_uint32(context: Context, object: JsValue, index: c_uint,
    value: JsValue
): c_int {
    return bridge.set_property_uint32(context, object, index, value);
}

pub fn get_property_str(context: Context, object: JsValue, name: c_str): JsValue {
    return bridge.get_property_str(context, object, name);
}

pub fn get_property_uint32(context: Context, object: JsValue,
    index: c_uint
): JsValue {
    return bridge.get_property_uint32(context, object, index);
}

pub fn get_array_buffer(context: Context, length: *c_size_t,
    value: JsValue
): ?*c_uchar {
    return bridge.get_array_buffer(context, length, value);
}

pub fn is_array(value: JsValue): c_int {
    return bridge.is_array(value);
}

pub fn read_int(context: Context, value: JsValue): ?i64 {
    var output_storage: [1]c_llong = [0];
    if bridge.to_int64(context, output_storage[..].ptr, value) != 0 {
        return none;
    }
    return output_storage[0] as i64;
}

pub fn read_number(context: Context, value: JsValue): ?f64 {
    var output_storage: [1]c_double = [0.0];
    if bridge.to_float64(context, output_storage[..].ptr, value) != 0 {
        return none;
    }
    return output_storage[0] as f64;
}

pub fn read_string(context: Context, value: JsValue): ?string {
    var length_storage: [1]c_size_t = [0];
    const pointer = bridge.to_c_string_len(
        context, length_storage[..].ptr, value, 0
    );
    if pointer is none {
        return none;
    }
    const length = length_storage[0];
    if length > 16 * 1024 * 1024 {
        bridge.free_c_string(context, pointer);
        return none;
    }
    var bytes: List<u8> = list<u8>();
    var index: usize = 0;
    while index < length as usize {
        unchecked {
            bytes.push(*(pointer + index) as u8);
        }
        index = index + 1;
    }
    bridge.free_c_string(context, pointer);
    return string.from(bytes[..]);
}

pub fn string(context: Context, value: string): JsValue {
    const bytes = value.bytes();
    return bridge.new_string_len(
        context,
        bytes.ptr as! *const c_char,
        bytes.len() as c_size_t
    );
}

pub fn type_error(context: Context, message: c_str): JsValue {
    return bridge.throw_value(context, bridge.new_type_error(context, message));
}

pub fn type_error_string(context: Context, message: string): JsValue {
    const error = bridge.new_error(context);
    const ignored = bridge.set_property_str(
        context, error, "message", string(context, message)
    );
    return bridge.throw_value(context, error);
}

pub fn set_number(context: Context, object: JsValue, name: c_str,
    value: f64
): void {
    const ignored = bridge.set_property_str(
        context, object, name, new_number(context, value)
    );
}

pub fn set_string(context: Context, object: JsValue, name: c_str,
    value: string
): void {
    const ignored = bridge.set_property_str(
        context, object, name, string(context, value)
    );
}

pub fn set_dynamic_string(context: Context, object: JsValue, name: string,
    value: string
): c_int {
    const bytes = name.bytes();
    const atom = bridge.new_atom_len(
        context,
        bytes.ptr as! *const c_char,
        bytes.len() as c_size_t
    );
    defer bridge.free_atom(context, atom);
    return bridge.set_property(
        context, object, atom, string(context, value)
    );
}

pub fn set_dynamic_value(context: Context, object: JsValue, name: string,
    value: JsValue
): c_int {
    const bytes = name.bytes();
    const atom = bridge.new_atom_len(
        context,
        bytes.ptr as! *const c_char,
        bytes.len() as c_size_t
    );
    defer bridge.free_atom(context, atom);
    return bridge.set_property(context, object, atom, value);
}

pub fn set_function(context: Context, object: JsValue, name: c_str,
    callback: Callback, argument_count: c_int
): void {
    const ignored = bridge.set_property_str(
        context,
        object,
        name,
        new_function(context, callback, name, argument_count, 0, 0)
    );
}

pub fn free_value(context: Context, value: JsValue): void {
    bridge.free_value(context, value);
}

pub fn dup_value(context: Context, value: JsValue): JsValue {
    return bridge.dup_value(context, value);
}
