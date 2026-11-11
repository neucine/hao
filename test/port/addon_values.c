#include "addon.h"
static JsValue inspect(JsContext *ctx, int argc, const JsValue *argv) {
    JsValue value = argc ? argv[0] : js_undefined(ctx);
    JsValue out = js_object(ctx);
    int flag = -1, integer = -1;
    double number = -1;
    js_to_bool(ctx, value, &flag);
    js_to_int32(ctx, value, &integer);
    js_to_float64(ctx, value, &number);
    js_set_property(ctx, out, "bool", js_bool(ctx, flag));
    js_set_property(ctx, out, "integer", js_int32(ctx, integer));
    js_set_property(ctx, out, "number", js_float64(ctx, number));
    js_set_property(ctx, out, "undefined", js_bool(ctx, js_is_undefined(ctx, value)));
    js_set_property(ctx, out, "null", js_bool(ctx, js_is_null(ctx, value)));
    js_set_property(ctx, out, "object", js_bool(ctx, js_is_object(ctx, value)));
    js_set_property(ctx, out, "array", js_bool(ctx, js_is_array(ctx, value)));
    js_set_property(ctx, out, "function", js_bool(ctx, js_is_function(ctx, value)));
    const char *text = js_to_string(ctx, value);
    if (text) js_set_property(ctx, out, "string", js_string(ctx, text));
    return out;
}
static const JsFunction functions[] = { {"inspect", inspect, 1} };
static const JsModule module = {"probe:native", functions, 1};
int js_register_modules(JsRegistry *registry) { return js_add_module(registry, &module); }
