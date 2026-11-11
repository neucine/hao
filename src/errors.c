#include <quickjs.h>
#include "runtime_host.h"
#include <execinfo.h>
#include <stdlib.h>
#include <string.h>

static JSValue capture_native_stack(JSContext *ctx, JSValueConst this_value,
                                    int argc, JSValueConst *argv) {
    (void)this_value;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (!host || !host->native_stack_trace_enabled) return JS_UNDEFINED;
    const char *name = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
    if (argc > 0 && !name) return JS_EXCEPTION;
    void *frames[64];
    int count = backtrace(frames, 64);
    char **symbols = count > 0 ? backtrace_symbols(frames, count) : NULL;
    char output[16384];
    size_t used = 0;
    const char *heading = name ? name : "NativeError";
    size_t length = strlen(heading);
    if (length > sizeof(output) - 1) length = sizeof(output) - 1;
    memcpy(output, heading, length);
    used = length;
    for (int i = 0; symbols && i < count && used + 2 < sizeof(output); i++) {
        output[used++] = '\n';
        length = strlen(symbols[i]);
        if (length > sizeof(output) - used - 1) length = sizeof(output) - used - 1;
        memcpy(output + used, symbols[i], length);
        used += length;
    }
    free(symbols);
    if (name) JS_FreeCString(ctx, name);
    return JS_NewStringLen(ctx, output, used);
}

int hao_install_runtime_error(JSContext *ctx) {
    const char *source =
        "if (typeof globalThis.RuntimeError !== 'function') {"
        "globalThis.RuntimeError = class RuntimeError extends Error {"
        "constructor(code, message) { super(message); this.name = 'RuntimeError'; this.code = code; }"
        "}; }";
    JSValue result = JS_Eval(ctx, source, strlen(source), "<runtime-errors>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        JS_FreeValue(ctx, result);
        return -1;
    }
    JS_FreeValue(ctx, result);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__hao_capture_native_stack",
        JS_NewCFunction(ctx, capture_native_stack, "captureNativeStack", 1));
    JS_FreeValue(ctx, global);
    return 0;
}
