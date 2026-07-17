#include "hao.h"

static HaoValue foo(HaoNativeContext* ctx, int argc, const HaoValue* argv) {
    (void)argc;
    (void)argv;
    return hao_string(ctx, "hao");
}

static HaoValue add(HaoNativeContext* ctx, int argc, const HaoValue* argv) {
    if (argc < 2) {
        return hao_throw_type_error(ctx, "add expects two numbers");
    }

    double a = 0;
    double b = 0;
    if (hao_to_float64(ctx, argv[0], &a) < 0 ||
        hao_to_float64(ctx, argv[1], &b) < 0) {
        return hao_throw_type_error(ctx, "add expects two numbers");
    }

    return hao_float64(ctx, a + b);
}

static const HaoNativeFunction functions[] = {
    { "foo", foo, 0 },
    { "add", add, 2 },
    { 0, 0, 0 },
};

static const HaoNativeModule module = {
    "foo:native",
    functions,
};

int hao_register_modules(HaoNativeRegistry* registry) {
    return hao_native_add_module(registry, &module);
}
