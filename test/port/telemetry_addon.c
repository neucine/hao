#include "addon.h"
#include <math.h>

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

static JsValue emit_root(JsContext *ctx, int argc, const JsValue *argv) {
    (void)argc;
    (void)argv;
    const JsTraceAttribute attributes[] = {
        {"flag", 0, 1, 0, 0.0, NULL},
        {"count", 1, 0, 3, 0.0, NULL},
        {"ratio", 2, 0, 0, 1.5, NULL},
        {"label", 3, 0, 0, 0.0, "fixture"},
    };
    const JsTraceSpanOptions options = {
        .root = 1,
        .kind = JS_SPAN_SERVER,
        .source = "fixture source",
        .attributes = attributes,
        .attribute_count = 4,
    };
    JsSpanHandle span = 0;
    if (js_trace_span_start(ctx, "fixture root", &options, &span) < 0)
        return js_throw_error(ctx, "root span start failed");
    if (js_trace_span_event(ctx, span, "fixture received", attributes, 4) < 0) {
        js_trace_span_end(ctx, span, JS_TRACE_STATUS_ERR);
        return js_throw_error(ctx, "root span event failed");
    }
    if (js_trace_span_end(ctx, span, JS_TRACE_STATUS_OK) < 0)
        return js_throw_error(ctx, "root span end failed");
    return js_undefined(ctx);
}

static JsValue probe_failures(JsContext *ctx, int argc, const JsValue *argv) {
    (void)argc;
    (void)argv;

    JsSpanHandle rejected = 0;
    const JsTraceAttribute bad_kind = {"bad", 9, 0, 0, 0.0, NULL};
    const JsTraceSpanOptions bad_options = {
        .attributes = &bad_kind,
        .attribute_count = 1,
    };
    if (js_trace_span_start(ctx, "rejected", &bad_options, &rejected) >= 0)
        return js_throw_error(ctx, "invalid attribute kind was accepted");

    const JsTraceAttribute bad_float = {"bad", 2, 0, 0, NAN, NULL};
    const JsTraceSpanOptions bad_float_options = {
        .attributes = &bad_float,
        .attribute_count = 1,
    };
    if (js_trace_span_start(ctx, "rejected", &bad_float_options, &rejected) >= 0)
        return js_throw_error(ctx, "nonfinite attribute was accepted");
    if (js_trace_span_event(ctx, 0, "missing", NULL, 0) >= 0 ||
        js_trace_span_end(ctx, 0, JS_TRACE_STATUS_OK) >= 0 ||
        js_trace_exit(ctx, 0) >= 0)
        return js_throw_error(ctx, "invalid span operation was accepted");

    JsTraceContext captured;
    if (js_trace_capture(ctx, &captured) < 0)
        return js_throw_error(ctx, "trace capture failed");
    JsSpanHandle scope = js_trace_enter(ctx, &captured);
    if (!scope || js_trace_exit(ctx, scope) < 0)
        return js_throw_error(ctx, "empty trace scope round trip failed");

    const JsTraceSpanOptions options = {.kind = JS_SPAN_INTERNAL};
    JsSpanHandle span = 0;
    if (js_trace_span_start(ctx, "failure-lifecycle", &options, &span) < 0)
        return js_throw_error(ctx, "failure span start failed");
    if (js_trace_span_end(ctx, span, 99) >= 0)
        return js_throw_error(ctx, "invalid span status was accepted");
    if (js_trace_span_end(ctx, span, JS_TRACE_STATUS_OK) < 0)
        return js_throw_error(ctx, "failure span cleanup failed");
    return js_undefined(ctx);
}

static const JsFunction functions[] = {
    {"emit", emit, 0},
    {"emitRoot", emit_root, 0},
    {"probeFailures", probe_failures, 0},
};
static const JsModule module = {"trace:native", functions, 3};

int js_register_modules(JsRegistry *registry) {
    if (registry->api->abi_version != JS_ADDON_ABI_VERSION) return -1;
    return js_add_module(registry, &module);
}
