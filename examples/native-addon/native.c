#include "addon.h"

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

static JsValue pair(JsContext* ctx, int argc, const JsValue* argv) {
    JsValue out = js_array(ctx);
    if (argc > 0 && js_array_set(ctx, out, 0, argv[0]) < 0) {
        return js_throw_error(ctx, "failed to set first array item");
    }
    if (argc > 1 && js_array_set(ctx, out, 1, argv[1]) < 0) {
        return js_throw_error(ctx, "failed to set second array item");
    }
    return out;
}

static JsValue label(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;
    return js_string(ctx, "extra");
}

static const JsFunction functions[] = {
    { "foo", foo, 0 },
    { "add", add, 2 },
    { "pair", pair, 2 },
    { 0, 0, 0 },
};

static const JsFunction extra_functions[] = {
    { "label", label, 0 },
    { 0, 0, 0 },
};

static const JsModule native_module = {
    "foo:native",
    functions,
};

static const JsModule extra_module = {
    "foo:extra",
    extra_functions,
};

int js_register_modules(JsRegistry* registry) {
    if (registry->api->abi_version != JS_ADDON_ABI_VERSION) {
        return -1;
    }
    if (js_add_module(registry, &native_module) != 0) {
        return -1;
    }
    return js_add_module(registry, &extra_module);
}
