#include <quickjs.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    size_t stdout_len;
    size_t stderr_len;
    int exit_code;
    int has_exit_code;
} HaoRunResult;

extern int hao_process_get_env(const unsigned char *name, unsigned char *output, size_t capacity);
extern int hao_process_run_json(const unsigned char *options, size_t options_len,
                                unsigned char *stdout_output, unsigned char *stderr_output,
                                size_t capacity, HaoRunResult *result);

static JSValue hao_get_env_native(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "getEnv requires a name");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_EXCEPTION;
    unsigned char value[65536];
    int length = hao_process_get_env((const unsigned char *)name, value, sizeof(value));
    JS_FreeCString(ctx, name);
    if (length == -1) return JS_NULL;
    if (length < 0) return JS_ThrowInternalError(ctx, "environment value is too large");
    return JS_NewStringLen(ctx, (const char *)value, (size_t)length);
}

static JSValue hao_run_native(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) {
        return JS_ThrowTypeError(ctx, "process.run requires an options object");
    }
    size_t capacity = 1024 * 1024;
    JSValue max_value = JS_GetPropertyStr(ctx, argv[0], "maxOutputBytes");
    if (JS_IsException(max_value)) return max_value;
    if (!JS_IsUndefined(max_value) && !JS_IsNull(max_value)) {
        int32_t requested = 0;
        if (JS_ToInt32(ctx, &requested, max_value) < 0) {
            JS_FreeValue(ctx, max_value);
            return JS_EXCEPTION;
        }
        if (requested < 1 || requested > 16 * 1024 * 1024) {
            JS_FreeValue(ctx, max_value);
            return JS_ThrowRangeError(ctx, "maxOutputBytes must be between 1 and 16777216");
        }
        capacity = (size_t)requested;
    }
    JS_FreeValue(ctx, max_value);
    JSValue json = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) return json;
    size_t json_len = 0;
    const char *options = JS_ToCStringLen(ctx, &json_len, json);
    JS_FreeValue(ctx, json);
    if (!options) return JS_EXCEPTION;
    if (json_len > 1024 * 1024) {
        JS_FreeCString(ctx, options);
        return JS_ThrowRangeError(ctx, "process options exceed 1 MiB");
    }
    unsigned char *stdout_buffer = malloc(capacity);
    unsigned char *stderr_buffer = malloc(capacity);
    if (!stdout_buffer || !stderr_buffer) {
        free(stdout_buffer);
        free(stderr_buffer);
        JS_FreeCString(ctx, options);
        return JS_ThrowOutOfMemory(ctx);
    }
    HaoRunResult run = {0};
    int status = hao_process_run_json((const unsigned char *)options, json_len,
                                      stdout_buffer, stderr_buffer, capacity, &run);
    JS_FreeCString(ctx, options);
    if (status != 0) {
        free(stdout_buffer);
        free(stderr_buffer);
        if (status == 1) return JS_ThrowTypeError(ctx, "invalid process options");
        if (status == 3) return JS_ThrowRangeError(ctx, "process output exceeds maxOutputBytes");
        return JS_ThrowInternalError(ctx, "process.run failed");
    }
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "stdout", JS_NewStringLen(ctx, (const char *)stdout_buffer, run.stdout_len));
    JS_SetPropertyStr(ctx, result, "stderr", JS_NewStringLen(ctx, (const char *)stderr_buffer, run.stderr_len));
    JS_SetPropertyStr(ctx, result, "exitCode", run.has_exit_code ? JS_NewInt32(ctx, run.exit_code) : JS_NULL);
    JS_SetPropertyStr(ctx, result, "signal", JS_NULL);
    free(stdout_buffer);
    free(stderr_buffer);
    return result;
}

void hao_install_process_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_process_getEnvNative", JS_NewCFunction(ctx, hao_get_env_native, "getEnvNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_process_runNative", JS_NewCFunction(ctx, hao_run_native, "runNative", 1));
}
