#include <quickjs.h>
#include <string.h>

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
    return 0;
}
