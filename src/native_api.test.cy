import { Runtime } from .runtime;
import { register_native_module } from .native_api;
import .js;

fn argument(arguments_pointer: *const js.JsValue, index: usize): js.JsValue {
    unchecked {
        return *(arguments_pointer + index);
    }
}

fn add_callback(context: js.Context, _: js.JsValue, argument_count: c_int,
    arguments_pointer: *const js.JsValue
): js.JsValue {
    if argument_count < 2 {
        return js.type_error(context, "add expects two numbers");
    }
    const left = js.read_number(context, argument(arguments_pointer, 0));
    const right = js.read_number(context, argument(arguments_pointer, 1));
    if left is first {
        if right is second {
            return js.new_number(context, first + second);
        }
    }
    return js.type_error(context, "add expects two numbers");
}

fn initialize(context: js.Context, module_ptr: js.Module): c_int {
    const exports = js.new_object(context);
    js.set_number(context, exports, "answer", 42.0);
    js.set_string(context, exports, "label", "hao-native");
    js.set_function(context, exports, "add", add_callback, 2);
    const ignored_boolean = js.set_property_str(
        context, exports, "enabled", js.bool(context, true)
    );
    const ignored_undefined = js.set_property_str(
        context, exports, "missing", js.undefined()
    );
    const values = js.new_array(context);
    const ignored_first = js.set_property_uint32(
        context, values, 0, js.new_number(context, 2.0)
    );
    const ignored_second = js.set_property_uint32(
        context, values, 1, js.new_number(context, 3.0)
    );
    const ignored_values = js.set_property_str(
        context, exports, "values", values
    );
    return js.set_module_export(context, module_ptr, "default", exports);
}

fn load_module(context: js.Context, name: *const c_char): js.Module {
    const module_ptr = js.new_module(context, name,
        c fn (module_context: js.Context, module_ptr: js.Module): c_int {
            return initialize(module_context, module_ptr);
        }
    );
    const ignored = js.add_module_export(context, module_ptr, "default");
    return module_ptr;
}

test "hao.js exposes a native module without JS declarations" {
    const runtime = Runtime.init();
    if runtime is host {
        defer host.deinit();
        assert(register_native_module(
            &host, "test:native",
            c fn (context: js.Context, name: *const c_char): js.Module {
                return load_module(context, name);
            }
        ) == 0);
        assert(host.eval(
            "import native from 'test:native';\nif (native.answer !== 42) throw new Error('number');\nif (native.label !== 'hao-native') throw new Error('string');\nif (native.enabled !== true) throw new Error('bool');\nif (native.missing !== undefined) throw new Error('undefined');\nif (native.values.length !== 2 || native.values[1] !== 3) throw new Error('array');\nif (native.add(2, 3) !== 5) throw new Error('function');\n",
            "<hao-native-api-test>"
        ) == 0);
        return;
    }
    assert(false);
}
