#include "hao.h"

static JsValue foo(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;
    return js_string(ctx, "hao");
}

static JsValue add(JsContext* ctx, int argc, const JsValue* argv) {
    if (argc < 2) {
        return js_throw_type_error(ctx, "add expects two numbers");
    }

    double a = 0;
    double b = 0;
    if (js_to_float64(ctx, argv[0], &a) < 0 ||
        js_to_float64(ctx, argv[1], &b) < 0) {
        return js_throw_type_error(ctx, "add expects two numbers");
    }

    return js_float64(ctx, a + b);
}

static const JsFunction functions[] = {
    { "foo", foo, 0 },
    { "add", add, 2 },
    { 0, 0, 0 },
};

static const JsModule module = {
    "foo:native",
    functions,
};

int js_register_modules(JsRegistry* registry) {
    return js_add_module(registry, &module);
}
