#include "addon.h"

static JsValue increment(JsContext *ctx, int argc, const JsValue *argv) {
    (void)argc; (void)argv;
    const JsMetricDefinition metric = {"addon", "calls", JS_METRIC_COUNTER, "count"};
    uint32_t id = 0;
    double value = 0;
    if (js_metric_register(ctx, &metric, &id) < 0 ||
        js_metric_add(ctx, id, 1) < 0 ||
        js_metric_value(ctx, id, &value) < 0)
        return js_throw_error(ctx, "addon metric failed");
    return js_float64(ctx, value);
}

static const JsFunction functions[] = {{"increment", increment, 0}};
static const JsModule module = {"metric:native", functions, 1};

int js_register_modules(JsRegistry *registry) {
    if (registry->api->abi_version != JS_ADDON_ABI_VERSION) return -1;
    return js_add_module(registry, &module);
}
