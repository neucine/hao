#include "cell.h"
#include "../bridge.h"
#include "../cyna_exports.h"
#include "../runtime_allocator.h"
#include "../runtime_host.h"
#include "../../../libs/transpiler/include/hao_transpiler.h"
#include <quickjs.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *hao_rewrite_cell_declarations(const char *source) {
    size_t length = strlen(source);
    if (length > (SIZE_MAX - 1) / 2) return NULL;
    size_t capacity = length * 2;
    char *output = hao_alloc(capacity + 1);
    if (!output) return NULL;
    size_t written = hao_jupyter_rewrite_cell((const unsigned char *)source,
        length, (unsigned char *)output, capacity);
    if (written > capacity) {
        hao_free(output);
        return NULL;
    }
    output[written] = 0;
    return output;
}

static char *hao_prepare_cell(JSContext *ctx, const char *source, const char *filename) {
    char *manifest_text = hao_transform_module(source, filename, 0, "__hao_jupyter_module_cache");
    if (!manifest_text) {
        char *error = hao_transpiler_last_error();
        JS_ThrowSyntaxError(ctx, "%s", error ? error : "Cell transpilation failed");
        if (error) hao_transpiler_free(error);
        return NULL;
    }
    JSValue manifest = JS_ParseJSON(ctx, manifest_text, strlen(manifest_text), filename);
    hao_transpiler_free(manifest_text);
    if (JS_IsException(manifest)) return NULL;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue cache = JS_GetPropertyStr(ctx, global, "__hao_jupyter_module_cache");
    if (JS_IsUndefined(cache)) {
        JS_FreeValue(ctx, cache);
        cache = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, global, "__hao_jupyter_module_cache", JS_DupValue(ctx, cache));
    }
    JSValue imports = JS_GetPropertyStr(ctx, manifest, "imports");
    JSValue count_value = JS_GetPropertyStr(ctx, imports, "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    char *code = NULL;
    for (uint32_t i = 0; i < count; i++) {
        JSValue item = JS_GetPropertyUint32(ctx, imports, i);
        JSValue source_value = JS_GetPropertyStr(ctx, item, "source");
        JSValue slot_value = JS_GetPropertyStr(ctx, item, "slot");
        const char *slot = JS_ToCString(ctx, slot_value);
        if (!slot) goto import_done;
        JSValue quoted = JS_JSONStringify(ctx, source_value, JS_UNDEFINED, JS_UNDEFINED);
        const char *quoted_text = JS_IsException(quoted) ? NULL : JS_ToCString(ctx, quoted);
        if (!quoted_text) { JS_FreeValue(ctx, quoted); goto import_done; }
        size_t helper_len = strlen(quoted_text) + 100;
        char *helper = hao_alloc(helper_len);
        if (helper) snprintf(helper, helper_len,
            "import * as __hao_ns from %s; globalThis.__hao_jupyter_import = __hao_ns;", quoted_text);
        JS_FreeCString(ctx, quoted_text);
        JS_FreeValue(ctx, quoted);
        if (!helper) { JS_ThrowOutOfMemory(ctx); goto import_done; }
        char helper_name[4096];
        snprintf(helper_name, sizeof(helper_name), "%s.import.%u.ts", filename, i);
        JSValue imported = JS_Eval(ctx, helper, strlen(helper), helper_name, JS_EVAL_TYPE_MODULE);
        hao_free(helper);
        if (JS_IsException(imported)) { JS_FreeValue(ctx, imported); goto import_done; }
        JS_FreeValue(ctx, imported);
        JSValue namespace_value = JS_GetPropertyStr(ctx, global, "__hao_jupyter_import");
        if (JS_SetPropertyStr(ctx, cache, slot, namespace_value) < 0) goto import_done;
        JS_FreeCString(ctx, slot);
        JS_FreeValue(ctx, slot_value); JS_FreeValue(ctx, source_value); JS_FreeValue(ctx, item);
        continue;
import_done:
        if (slot) JS_FreeCString(ctx, slot);
        JS_FreeValue(ctx, slot_value); JS_FreeValue(ctx, source_value); JS_FreeValue(ctx, item);
        goto done;
    }
    JSValue exports_slot_value = JS_GetPropertyStr(ctx, manifest, "exports_slot");
    const char *exports_slot = JS_ToCString(ctx, exports_slot_value);
    if (exports_slot) {
        if (JS_SetPropertyStr(ctx, cache, exports_slot, JS_NewObject(ctx)) < 0) {
            JS_FreeCString(ctx, exports_slot);
            JS_FreeValue(ctx, exports_slot_value);
            goto done;
        }
        JS_FreeCString(ctx, exports_slot);
    } else { JS_FreeValue(ctx, exports_slot_value); goto done; }
    JS_FreeValue(ctx, exports_slot_value);
    JSValue code_value = JS_GetPropertyStr(ctx, manifest, "code");
    const char *raw_code = JS_ToCString(ctx, code_value);
    if (raw_code) {
        code = hao_rewrite_cell_declarations(raw_code);
        JS_FreeCString(ctx, raw_code);
        if (!code) JS_ThrowOutOfMemory(ctx);
    }
    JS_FreeValue(ctx, code_value);
done:
    JS_FreeValue(ctx, imports); JS_FreeValue(ctx, cache);
    JS_FreeValue(ctx, global); JS_FreeValue(ctx, manifest);
    return code;
}

static JSValue hao_cell_repr(JSContext *ctx, JSValueConst value, JSValue *mime) {
    *mime = JS_NewString(ctx, "text/plain");
    if (!JS_IsObject(value)) return JS_DupValue(ctx, value);
    JSValue method = JS_GetPropertyStr(ctx, value, "repr");
    if (JS_IsException(method)) return method;
    if (JS_IsFunction(ctx, method)) {
        JSValue options = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, options, "mode", JS_NewString(ctx, "text"));
        JSValue answer = JS_Call(ctx, method, value, 1, &options);
        JS_FreeValue(ctx, options);
        JS_FreeValue(ctx, method);
        if (JS_IsException(answer)) return answer;
        if (JS_IsObject(answer)) {
            JSValue data = JS_GetPropertyStr(ctx, answer, "data");
            JSValue kind = JS_GetPropertyStr(ctx, answer, "mime");
            if (!JS_IsUndefined(data) && !JS_IsNull(data) && !JS_IsUndefined(kind) && !JS_IsNull(kind)) {
                JS_FreeValue(ctx, *mime);
                *mime = kind;
                JS_FreeValue(ctx, answer);
                return data;
            }
            JS_FreeValue(ctx, data);
            JS_FreeValue(ctx, kind);
        } else if (JS_IsString(answer)) return answer;
        JS_FreeValue(ctx, answer);
    } else JS_FreeValue(ctx, method);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue inspect = JS_GetPropertyStr(ctx, global, "__hao_jupyter_inspect");
    JS_FreeValue(ctx, global);
    if (JS_IsFunction(ctx, inspect)) {
        JSValue answer = JS_Call(ctx, inspect, JS_UNDEFINED, 1, &value);
        JS_FreeValue(ctx, inspect);
        if (!JS_IsException(answer)) return answer;
        return answer;
    }
    JS_FreeValue(ctx, inspect);
    JSValue json = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    if (!JS_IsException(json) && !JS_IsUndefined(json)) return json;
    if (JS_IsException(json)) { JSValue error = JS_GetException(ctx); JS_FreeValue(ctx, error); }
    JS_FreeValue(ctx, json);
    return JS_DupValue(ctx, value);
}

static JSValue hao_cell_error_text(JSContext *ctx, JSValueConst exception) {
    if (!JS_IsObject(exception)) return JS_DupValue(ctx, exception);
    JSValue name_value = JS_GetPropertyStr(ctx, exception, "name");
    JSValue message_value = JS_GetPropertyStr(ctx, exception, "message");
    JSValue stack_value = JS_GetPropertyStr(ctx, exception, "stack");
    const char *name = JS_IsNull(name_value) || JS_IsUndefined(name_value) ? NULL : JS_ToCString(ctx, name_value);
    const char *message = JS_IsNull(message_value) || JS_IsUndefined(message_value) ? NULL : JS_ToCString(ctx, message_value);
    const char *stack = JS_IsNull(stack_value) || JS_IsUndefined(stack_value) ? NULL : JS_ToCString(ctx, stack_value);
    JSValue text = JS_DupValue(ctx, exception);
    if (name || message || stack) {
        const char *label = name ? name : "Error";
        size_t length = strlen(label) + (message ? strlen(message) + 2 : 0) +
                        (stack ? strlen(stack) + 1 : 0) + 1;
        char *buffer = hao_alloc(length);
        if (buffer) {
            snprintf(buffer, length, "%s%s%s%s%s", label, message ? ": " : "",
                     message ? message : "", stack ? "\n" : "", stack ? stack : "");
            JS_FreeValue(ctx, text);
            text = JS_NewString(ctx, buffer);
            hao_free(buffer);
        }
    }
    if (name) JS_FreeCString(ctx, name);
    if (message) JS_FreeCString(ctx, message);
    if (stack) JS_FreeCString(ctx, stack);
    JS_FreeValue(ctx, name_value);
    JS_FreeValue(ctx, message_value);
    JS_FreeValue(ctx, stack_value);
    return text;
}

static bool hao_cell_is_promise_like(JSContext *ctx, JSValueConst value) {
    if (!JS_IsObject(value)) return false;
    JSValue then = JS_GetPropertyStr(ctx, value, "then");
    bool found = JS_IsFunction(ctx, then);
    JS_FreeValue(ctx, then);
    return found;
}

static JSValue hao_cell_await(JSContext *ctx, HaoRuntime *host, JSValueConst promise) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue state = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, state, "settled", JS_NewBool(ctx, false));
    JS_SetPropertyStr(ctx, state, "ok", JS_NewBool(ctx, false));
    JS_SetPropertyStr(ctx, global, "__hao_nb_async_state", JS_DupValue(ctx, state));
    JS_SetPropertyStr(ctx, global, "__hao_nb_async_promise", JS_DupValue(ctx, promise));
    static const char bootstrap[] =
        "((s, p) => Promise.resolve(p).then("
        "value => { s.value = value; s.ok = true; s.settled = true; },"
        "error => { s.value = error; s.settled = true; }))"
        "(globalThis.__hao_nb_async_state, globalThis.__hao_nb_async_promise);";
    JSValue setup = JS_Eval(ctx, bootstrap, sizeof(bootstrap) - 1,
                            "<hao-jupyter-await>", JS_EVAL_TYPE_GLOBAL);
    JSValue outcome = JS_UNDEFINED;
    if (JS_IsException(setup)) {
        outcome = setup;
    } else {
        JS_FreeValue(ctx, setup);
        bool completed = false;
        int idle_rounds = 0;
        for (int i = 0; i < 10000; i++) {
            JSValue settled = JS_GetPropertyStr(ctx, state, "settled");
            int ready = JS_ToBool(ctx, settled);
            JS_FreeValue(ctx, settled);
            if (ready) {
                JSValue ok = JS_GetPropertyStr(ctx, state, "ok");
                int success = JS_ToBool(ctx, ok);
                JS_FreeValue(ctx, ok);
                outcome = JS_GetPropertyStr(ctx, state, "value");
                if (!success) JS_Throw(ctx, JS_DupValue(ctx, outcome));
                if (!success) { JS_FreeValue(ctx, outcome); outcome = JS_EXCEPTION; }
                completed = true;
                break;
            }
            JSContext *job_ctx = NULL;
            int ran_jobs = JS_ExecutePendingJob(host->runtime, &job_ctx);
            if (ran_jobs < 0) {
                JSValue error = JS_GetException(job_ctx);
                JS_Throw(ctx, error);
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            if (host->has_rejection) {
                JS_Throw(ctx, JS_DupValue(host->rejection_context, host->rejection));
                JS_FreeValue(host->rejection_context, host->rejection);
                host->has_rejection = false;
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            int ran_io = hao_async_uv_run_nowait(host->loop);
            if (ran_io < 0) {
                JS_ThrowInternalError(ctx, "libuv run failed");
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            if (host->has_callback_error) {
                JS_Throw(ctx, JS_DupValue(ctx, host->callback_error));
                JS_FreeValue(ctx, host->callback_error);
                host->has_callback_error = false;
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            if (host->has_rejection) {
                JS_Throw(ctx, JS_DupValue(host->rejection_context, host->rejection));
                JS_FreeValue(host->rejection_context, host->rejection);
                host->has_rejection = false;
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            if (ran_jobs == 0 && ran_io == 0) {
                if (++idle_rounds >= 64) {
                    JS_ThrowInternalError(ctx, "Promise did not settle");
                    outcome = JS_EXCEPTION;
                    completed = true;
                    break;
                }
            } else {
                idle_rounds = 0;
            }
        }
        if (!completed) {
            JS_ThrowInternalError(ctx, "Promise did not settle");
            outcome = JS_EXCEPTION;
        }
    }
    JS_SetPropertyStr(ctx, global, "__hao_nb_async_state", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global, "__hao_nb_async_promise", JS_UNDEFINED);
    JS_FreeValue(ctx, state);
    JS_FreeValue(ctx, global);
    return outcome;
}

char *hao_runtime_eval_cell(uintptr_t handle, const char *source, size_t source_len,
                            const char *filename, size_t filename_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!host || source_len > 1024 * 1024 || filename_len > 4096 || host->capture_active) return NULL;
    char *input = hao_alloc(source_len + 1);
    char *name = hao_alloc(filename_len + 1);
    if (!input || !name) { hao_free(input); hao_free(name); return NULL; }
    memcpy(input, source, source_len); input[source_len] = 0;
    memcpy(name, filename, filename_len); name[filename_len] = 0;
    if (name[0] != '/') {
        char *cwd = getcwd(NULL, 0);
        if (!cwd) { hao_free(input); hao_free(name); return NULL; }
        size_t needed = strlen(cwd) + filename_len + 2;
        char *absolute = hao_alloc(needed);
        if (!absolute) { free(cwd); hao_free(input); hao_free(name); return NULL; }
        snprintf(absolute, needed, "%s/%s", cwd, name);
        free(cwd);
        hao_free(name);
        name = absolute;
    }
    host->capture_stdout_len = host->capture_stderr_len = 0;
    host->capture_target = 3;
    host->capture_active = true;
    JSContext *ctx = host->context;
    char *transformed = hao_prepare_cell(ctx, input, name);
    hao_free(input);
    JSValue result = JS_UNDEFINED;
    JSValue exception = JS_UNDEFINED;
    if (transformed) {
        result = JS_Eval(ctx, transformed, strlen(transformed), name, JS_EVAL_TYPE_GLOBAL);
        hao_free(transformed);
        if (JS_IsException(result)) exception = JS_GetException(ctx);
        else if (hao_cell_is_promise_like(ctx, result)) {
            JSValue settled = hao_cell_await(ctx, host, result);
            JS_FreeValue(ctx, result);
            result = settled;
            if (JS_IsException(result)) exception = JS_GetException(ctx);
        }
    } else {
        exception = JS_GetException(ctx);
    }
    hao_free(name);
    if (JS_IsUndefined(exception)) {
        JSContext *job_ctx = NULL;
        for (int i = 0; i < 10000; i++) {
            int jobs = JS_ExecutePendingJob(host->runtime, &job_ctx);
            if (jobs < 0) { exception = JS_GetException(job_ctx); break; }
            int io = hao_async_uv_run_nowait(host->loop);
            if (jobs == 0 && io == 0) break;
        }
    }
    if (host->has_callback_error) {
        if (JS_IsUndefined(exception)) exception = JS_DupValue(ctx, host->callback_error);
        JS_FreeValue(ctx, host->callback_error);
        host->has_callback_error = false;
    }
    if (host->has_rejection) {
        if (JS_IsUndefined(exception)) exception = JS_DupValue(host->rejection_context, host->rejection);
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
    }
    host->capture_active = false;
    JSValue packet = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, packet, "stdout", JS_NewStringLen(ctx, host->capture_stdout, host->capture_stdout_len));
    JS_SetPropertyStr(ctx, packet, "stderr", JS_NewStringLen(ctx, host->capture_stderr, host->capture_stderr_len));
    JSValue mime = JS_UNDEFINED;
    JSValue display = JS_IsUndefined(exception) ? hao_cell_repr(ctx, result, &mime) : hao_cell_error_text(ctx, exception);
    if (JS_IsException(display)) {
        JS_FreeValue(ctx, display);
        display = JS_GetException(ctx);
        JS_FreeValue(ctx, exception);
        exception = JS_DupValue(ctx, display);
    }
    size_t value_len = 0;
    const char *value = JS_ToCStringLen(ctx, &value_len, display);
    JS_SetPropertyStr(ctx, packet, "value", value ? JS_NewStringLen(ctx, value, value_len) : JS_NULL);
    if (!JS_IsUndefined(mime)) JS_SetPropertyStr(ctx, packet, "mime", mime);
    JS_SetPropertyStr(ctx, packet, "error", JS_NewBool(ctx, !JS_IsUndefined(exception)));
    /* Zig's notebook formatter omits an empty primitive string result. */
    bool has_value = JS_IsUndefined(exception) && !JS_IsUndefined(result) && !JS_IsNull(result);
    if (has_value && JS_IsString(result)) {
        size_t string_len = 0;
        const char *string_value = JS_ToCStringLen(ctx, &string_len, result);
        if (string_value && string_len == 0) has_value = false;
        if (string_value) JS_FreeCString(ctx, string_value);
    }
    JS_SetPropertyStr(ctx, packet, "has_value", JS_NewBool(ctx, has_value));
    if (value) JS_FreeCString(ctx, value);
    JS_FreeValue(ctx, display);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, exception);
    JSValue encoded = JS_JSONStringify(ctx, packet, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, packet);
    if (JS_IsException(encoded)) { JS_FreeValue(ctx, encoded); return NULL; }
    const char *text = JS_ToCString(ctx, encoded);
    char *copy = text ? hao_strdup(text) : NULL;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, encoded);
    return copy;
}

void hao_runtime_free_text(const char *text) { hao_free((void *)text); }
