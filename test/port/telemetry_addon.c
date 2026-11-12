#include "addon.h"

static JsValue emit(JsContext *ctx, int argc, const JsValue *argv) {
    (void)argc;
    (void)argv;
    JsTraceContext captured;
    if (js_trace_capture(ctx, &captured) < 0)
        return js_throw_error(ctx, "trace capture failed");
    JsSpanHandle scope = js_trace_enter(ctx, &captured);
    if (!scope) return js_throw_error(ctx, "trace enter failed");

    const JsTraceAttribute start_attributes[] = {
        {"native", 0, 1, 0, 0.0, NULL},
    };
    const JsTraceSpanOptions options = {
        .root = 0,
        .kind = JS_SPAN_CLIENT,
        .source = "telemetry:native",
        .attributes = start_attributes,
        .attribute_count = 1,
    };
    JsSpanHandle span = 0;
    if (js_trace_span_start(ctx, "addon-work", &options, &span) < 0) {
        js_trace_exit(ctx, scope);
        return js_throw_error(ctx, "span start failed");
    }

    const JsTraceAttribute event_attributes[] = {
        {"records", 1, 0, 2, 0.0, NULL},
    };
    if (js_trace_span_event(ctx, span, "addon-event", event_attributes, 1) < 0) {
        js_trace_span_end(ctx, span, JS_TRACE_STATUS_ERR);
        js_trace_exit(ctx, scope);
        return js_throw_error(ctx, "span event failed");
    }
    if (js_trace_span_end(ctx, span, JS_TRACE_STATUS_OK) < 0) {
        js_trace_exit(ctx, scope);
        return js_throw_error(ctx, "span end failed");
    }
    if (js_trace_exit(ctx, scope) < 0)
        return js_throw_error(ctx, "trace exit failed");
    return js_undefined(ctx);
}

static const JsFunction functions[] = {{"emit", emit, 0}};
static const JsModule module = {"trace:native", functions, 1};

int js_register_modules(JsRegistry *registry) {
    if (registry->api->abi_version != JS_ADDON_ABI_VERSION) return -1;
    return js_add_module(registry, &module);
}
