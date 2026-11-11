#include <quickjs.h>
#include "../../runtime_allocator.h"
#include "../../cyna_exports.h"
#include <stdint.h>
#include <stdlib.h>

static JSValue option_type_error(JSContext *ctx, const char *message) {
    JSValue pending = JS_GetException(ctx);
    JS_FreeValue(ctx, pending);
    return JS_ThrowTypeError(ctx, "%s", message);
}

static int copy_string_option(JSContext *ctx, JSValue target, JSValueConst source,
                              const char *name, int required) {
    JSValue value = JS_GetPropertyStr(ctx, source, name);
    if (JS_IsException(value)) return -1;
    if (JS_IsNull(value) || JS_IsUndefined(value)) {
        JS_FreeValue(ctx, value);
        return required ? 1 : 0;
    }
    JSValue text = JS_ToString(ctx, value);
    JS_FreeValue(ctx, value);
    if (JS_IsException(text)) return -1;
    return JS_SetPropertyStr(ctx, target, name, text) < 0 ? -1 : 0;
}

static JSValue normalized_options(JSContext *ctx, JSValueConst options) {
    JSValue normalized = JS_NewObject(ctx);
    if (JS_IsException(normalized)) return normalized;
    int status = copy_string_option(ctx, normalized, options, "cmd", 1);
    if (status != 0) {
        JS_FreeValue(ctx, normalized);
        return status > 0 ? JS_ThrowTypeError(ctx, "process.run requires options.cmd")
                          : option_type_error(ctx, "process.run requires options.cmd");
    }
    JSValue args = JS_GetPropertyStr(ctx, options, "args");
    if (JS_IsException(args)) {
        JS_FreeValue(ctx, normalized);
        return option_type_error(ctx, "process.run args must be a string array");
    }
    if (!JS_IsNull(args) && !JS_IsUndefined(args)) {
        if (!JS_IsArray(args)) {
            JS_FreeValue(ctx, args);
            JS_FreeValue(ctx, normalized);
            return JS_ThrowTypeError(ctx, "process.run args must be a string array");
        }
        JSValue length_value = JS_GetPropertyStr(ctx, args, "length");
        uint32_t length = 0;
        if (JS_IsException(length_value) || JS_ToUint32(ctx, &length, length_value) < 0) {
            JS_FreeValue(ctx, length_value);
            JS_FreeValue(ctx, args);
            JS_FreeValue(ctx, normalized);
            return option_type_error(ctx, "process.run args must be a string array");
        }
        JS_FreeValue(ctx, length_value);
        JSValue converted = JS_NewArray(ctx);
        if (JS_IsException(converted)) { JS_FreeValue(ctx, args); JS_FreeValue(ctx, normalized); return converted; }
        for (uint32_t i = 0; i < length; ++i) {
            JSValue value = JS_GetPropertyUint32(ctx, args, i);
            if (JS_IsException(value)) {
                JS_FreeValue(ctx, converted); JS_FreeValue(ctx, args); JS_FreeValue(ctx, normalized);
                return option_type_error(ctx, "process.run args must be a string array");
            }
            JSValue text = JS_ToString(ctx, value);
            JS_FreeValue(ctx, value);
            if (JS_IsException(text) || JS_SetPropertyUint32(ctx, converted, i, text) < 0) {
                JS_FreeValue(ctx, converted);
                JS_FreeValue(ctx, args);
                JS_FreeValue(ctx, normalized);
                return option_type_error(ctx, "process.run args must be a string array");
            }
        }
        if (JS_SetPropertyStr(ctx, normalized, "args", converted) < 0) {
            JS_FreeValue(ctx, args);
            JS_FreeValue(ctx, normalized);
            return option_type_error(ctx, "process.run args must be a string array");
        }
    }
    JS_FreeValue(ctx, args);
    status = copy_string_option(ctx, normalized, options, "cwd", 0);
    if (status != 0) {
        JS_FreeValue(ctx, normalized);
        return option_type_error(ctx, "process.run cwd must be a string");
    }
    return normalized;
}

static JSValue hao_get_env_native(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "getEnvNative expects a variable name");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) return option_type_error(ctx, "getEnvNative expects a variable name");
    const char *value = getenv(name);
    JS_FreeCString(ctx, name);
    return value ? JS_NewString(ctx, value) : JS_NULL;
}

static JSValue hao_run_native(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) {
        return JS_ThrowTypeError(ctx, "process.run requires an options object");
    }
    JSValue prepared = normalized_options(ctx, argv[0]);
    if (JS_IsException(prepared)) return prepared;
    size_t capacity = 1024 * 1024;
    JSValue max_value = JS_GetPropertyStr(ctx, argv[0], "maxOutputBytes");
    if (JS_IsException(max_value)) {
        JS_FreeValue(ctx, prepared);
        return option_type_error(ctx, "process.run maxOutputBytes must be positive");
    }
    if (!JS_IsUndefined(max_value) && !JS_IsNull(max_value)) {
        int32_t requested = 0;
        if (JS_ToInt32(ctx, &requested, max_value) < 0) {
            JS_FreeValue(ctx, max_value);
            JS_FreeValue(ctx, prepared);
            return option_type_error(ctx, "process.run maxOutputBytes must be positive");
        }
        if (requested < 1) {
            JS_FreeValue(ctx, max_value);
            JS_FreeValue(ctx, prepared);
            return JS_ThrowTypeError(ctx, "process.run maxOutputBytes must be positive");
        }
        capacity = (size_t)requested;
    }
    JS_FreeValue(ctx, max_value);
    JSValue json = JS_JSONStringify(ctx, prepared, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, prepared);
    if (JS_IsException(json)) return json;
    size_t json_len = 0;
    const char *options = JS_ToCStringLen(ctx, &json_len, json);
    JS_FreeValue(ctx, json);
    if (!options) return JS_EXCEPTION;
    unsigned char *stdout_buffer = hao_alloc(capacity + 1);
    unsigned char *stderr_buffer = hao_alloc(capacity + 1);
    if (!stdout_buffer || !stderr_buffer) {
        hao_free(stdout_buffer);
        hao_free(stderr_buffer);
        JS_FreeCString(ctx, options);
        return JS_ThrowOutOfMemory(ctx);
    }
    HaoRunResult run = {0};
    int status = hao_process_run_json((const unsigned char *)options, json_len,
                                      stdout_buffer, stderr_buffer, capacity, &run);
    JS_FreeCString(ctx, options);
    if (status != 0) {
        hao_free(stdout_buffer);
        hao_free(stderr_buffer);
        if (status == 1) return JS_ThrowTypeError(ctx, "invalid process options");
        if (status == 3) return JS_ThrowInternalError(ctx, "process.run failed");
        return JS_ThrowInternalError(ctx, "process.run failed");
    }
    stdout_buffer[run.stdout_len] = 0;
    stderr_buffer[run.stderr_len] = 0;
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "stdout", JS_NewString(ctx, (const char *)stdout_buffer));
    JS_SetPropertyStr(ctx, result, "stderr", JS_NewString(ctx, (const char *)stderr_buffer));
    JS_SetPropertyStr(ctx, result, "exitCode", run.has_exit_code ? JS_NewInt32(ctx, run.exit_code) : JS_NULL);
    JS_SetPropertyStr(ctx, result, "signal", run.has_signal ? JS_NewInt32(ctx, run.signal) : JS_NULL);
    hao_free(stdout_buffer);
    hao_free(stderr_buffer);
    return result;
}

void hao_install_process_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_process_getEnvNative", JS_NewCFunction(ctx, hao_get_env_native, "getEnvNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_process_runNative", JS_NewCFunction(ctx, hao_run_native, "runNative", 1));
}
