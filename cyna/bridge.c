#include <quickjs.h>
#include "src/runtime_allocator.h"
#include <uv.h>
#include <stdbool.h>
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static bool positive_size_env(const char *name, size_t *out, bool *present) {
    const char *value = getenv(name);
    *present = value != NULL;
    if (!*present) return true;
    if (!*value || *value == '-' || isspace((unsigned char)*value)) return false;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno || !end || *end || parsed == 0 || parsed > SIZE_MAX) return false;
    *out = (size_t)parsed;
    return true;
}

#include "src/runtime_host.h"

extern char *hao_transpile_types_for_path(const char *source, const char *source_path);
extern char *hao_transform_module(const char *source, const char *source_path,
                                  uint8_t isolated, const char *namespace_root);
extern char *hao_transpiler_last_error(void);
extern void hao_transpiler_free(char *text);
extern void hao_install_fs_globals(JSContext *ctx, JSValue global);
extern void hao_install_process_globals(JSContext *ctx, JSValue global);
extern void hao_install_http_globals(JSContext *ctx, JSValue global);
extern void hao_install_http_server_globals(JSContext *ctx, JSValue global);
extern void hao_http_server_cleanup(JSContext *ctx);
extern void hao_install_telemetry_globals(JSContext *ctx, JSValue global);
extern void hao_metric_cleanup(JSContext *ctx);
extern void hao_install_ffi_globals(JSContext *ctx, JSValue global);
extern void hao_ffi_cleanup(JSContext *ctx);
extern JSModuleDef *hao_load_addon(JSContext *ctx, const char *name);
extern void hao_addon_cleanup(JSContext *ctx);
extern int hao_resolve_package(const unsigned char *base, const unsigned char *specifier,
                               unsigned char *output, size_t capacity);
extern int hao_install_runtime_error(JSContext *ctx);
extern int hao_test_reporter_ansi(void);
void hao_runtime_free(uintptr_t handle);

void hao_runtime_set_telemetry_console(uintptr_t handle, int enabled, uint16_t port) {
    HaoRuntime *host = (HaoRuntime *)handle;
    host->telemetry_trace_enabled = enabled != 0;
    JSValue global = JS_GetGlobalObject(host->context);
    if (!enabled) JS_SetPropertyStr(host->context, global, "__hao_trace_capacity", JS_NewUint32(host->context, 0));
    JS_SetPropertyStr(host->context, global, "__hao_telemetry_console_enabled", JS_NewBool(host->context, enabled));
    JS_SetPropertyStr(host->context, global, "__hao_telemetry_console_port", JS_NewUint32(host->context, port));
    JS_FreeValue(host->context, global);
}

void hao_runtime_set_native_stack_trace(uintptr_t handle, int enabled) {
    ((HaoRuntime *)handle)->native_stack_trace_enabled = enabled != 0;
}

static void hao_print_value(JSContext *ctx, JSValueConst error) {
    JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
    const char *text = JS_ToCString(ctx, error);
    if (text) {
        HaoRuntime *host = JS_GetContextOpaque(ctx);
        if (host) {
            hao_free(host->embed_error);
            host->embed_error = hao_strdup(text);
        }
    }
    const char *stack_text = JS_IsUndefined(stack) ? NULL : JS_ToCString(ctx, stack);
    JSValue message = JS_GetPropertyStr(ctx, error, "message");
    const char *message_text = JS_IsUndefined(message) ? NULL : JS_ToCString(ctx, message);
    if (stack_text && *stack_text) {
        if (message_text && !strstr(stack_text, message_text)) fprintf(stderr, "%s\n", message_text);
        fprintf(stderr, "%s\n", stack_text);
    } else if (message_text) fprintf(stderr, "%s\n", message_text);
    else if (text) fprintf(stderr, "%s\n", text);
    if (message_text) JS_FreeCString(ctx, message_text);
    JS_FreeValue(ctx, message);
    if (stack_text) JS_FreeCString(ctx, stack_text);
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, stack);
}

static void hao_print_exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    hao_print_value(ctx, error);
    JS_FreeValue(ctx, error);
}

static void hao_on_rejection(JSContext *ctx, JSValueConst promise,
                             JSValueConst reason, bool is_handled, void *opaque) {
    (void)promise;
    HaoRuntime *host = opaque;
    if (host->has_rejection) {
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
    }
    if (!is_handled) {
        host->rejection = JS_DupValue(ctx, reason);
        host->rejection_context = ctx;
        host->has_rejection = true;
    }
}

int hao_embed_bytes_valid(const unsigned char *pointer, size_t length) {
    return pointer != NULL || length == 0;
}

void hao_embed_clear_error(uintptr_t handle) {
    if (!handle) return;
    HaoRuntime *host = (HaoRuntime *)handle;
    hao_free(host->embed_error);
    host->embed_error = NULL;
}

void hao_embed_invalid_buffer(uintptr_t handle) {
    if (!handle) return;
    hao_embed_clear_error(handle);
    ((HaoRuntime *)handle)->embed_error = hao_strdup("Invalid byte buffer");
}

void hao_embed_set_error(uintptr_t handle, const unsigned char *message, size_t length) {
    if (!handle || !message || length == SIZE_MAX) return;
    HaoRuntime *host = (HaoRuntime *)handle;
    if (host->embed_error) return;
    char *copy = hao_alloc(length + 1);
    if (!copy) return;
    memcpy(copy, message, length);
    copy[length] = 0;
    host->embed_error = copy;
}

size_t hao_embed_last_error(uintptr_t handle, unsigned char *output, size_t capacity) {
    if (!handle) return 0;
    const char *error = ((HaoRuntime *)handle)->embed_error;
    if (!error) return 0;
    size_t length = strlen(error);
    if (output && capacity) {
        size_t count = length < capacity - 1 ? length : capacity - 1;
        memcpy(output, error, count);
        output[count] = 0;
    }
    return length;
}

uintptr_t hao_runtime_new(void) {
    size_t stack_size = 8 * 1024 * 1024, gc_threshold = 0, thread_pool_size = 0;
    size_t trace_records = 4096;
    bool stack_present = false, gc_present = false, pool_present = false, trace_present = false;
    if (!positive_size_env("RUNTIME_QJS_STACK_SIZE", &stack_size, &stack_present) ||
        !positive_size_env("RUNTIME_QJS_GC_THRESHOLD", &gc_threshold, &gc_present) ||
        !positive_size_env("RUNTIME_LIBUV_THREADPOOL_SIZE", &thread_pool_size, &pool_present) ||
        !positive_size_env("RUNTIME_TELEMETRY_TRACE_RECORDS", &trace_records, &trace_present) ||
        trace_records > 1048576) {
        fprintf(stderr, "Invalid Hao runtime size setting\n");
        return 0;
    }
    if (pool_present) {
        char buffer[32];
        snprintf(buffer, sizeof(buffer), "%zu", thread_pool_size);
        if (setenv("UV_THREADPOOL_SIZE", buffer, 1) != 0) return 0;
    }
    HaoRuntime *host = hao_calloc(1, sizeof(*host));
    if (!host) return 0;
    if (pthread_mutex_init(&host->telemetry_mutex, NULL) != 0) {
        hao_free(host);
        return 0;
    }
    host->runtime = JS_NewRuntime();
    if (!host->runtime) {
        pthread_mutex_destroy(&host->telemetry_mutex);
        hao_free(host);
        return 0;
    }
    JS_SetMaxStackSize(host->runtime, stack_size);
    if (gc_present) JS_SetGCThreshold(host->runtime, gc_threshold);
    JS_SetHostPromiseRejectionTracker(host->runtime, hao_on_rejection, host);
    host->context = JS_NewContext(host->runtime);
    if (!host->context) {
        JS_FreeRuntime(host->runtime);
        pthread_mutex_destroy(&host->telemetry_mutex);
        hao_free(host);
        return 0;
    }
    host->loop = hao_async_uv_new();
    if (!host->loop) {
        JS_FreeContext(host->context);
        JS_FreeRuntime(host->runtime);
        pthread_mutex_destroy(&host->telemetry_mutex);
        hao_free(host);
        return 0;
    }
    host->next_timer_id = 1;
    JS_SetContextOpaque(host->context, host);
    JS_SetModuleLoaderFunc(host->runtime, hao_normalize_module, hao_load_module, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__hao_trace_capacity", JS_NewUint32(host->context, (uint32_t)trace_records));
    hao_install_fs_globals(host->context, global);
    hao_install_process_globals(host->context, global);
    hao_install_http_globals(host->context, global);
    hao_install_http_server_globals(host->context, global);
    hao_install_telemetry_globals(host->context, global);
    hao_install_telemetry_interface(host->context, global);
    hao_install_ffi_globals(host->context, global);
    JS_FreeValue(host->context, global);
    if (hao_install_runtime_error(host->context) != 0) {
        hao_print_exception(host->context);
        hao_runtime_free((uintptr_t)host);
        return 0;
    }
    return (uintptr_t)host;
}

void hao_runtime_free(uintptr_t handle) {
    if (!handle) return;
    HaoRuntime *host = (HaoRuntime *)handle;
    hao_http_server_cleanup(host->context);
    hao_ffi_cleanup(host->context);
    hao_addon_cleanup(host->context);
    hao_package_cleanup(host);
    hao_metric_cleanup(host->context);
    hao_telemetry_cleanup(host);
    hao_cleanup_timers(host);
    hao_async_uv_free(host->loop);
    hao_free(host->capture_stdout);
    hao_free(host->capture_stderr);
    hao_free(host->embed_error);
    if (host->has_rejection) JS_FreeValue(host->rejection_context, host->rejection);
    if (host->has_callback_error) JS_FreeValue(host->context, host->callback_error);
    JS_FreeContext(host->context);
    JS_FreeRuntime(host->runtime);
    hao_module_cleanup(host);
    pthread_mutex_destroy(&host->telemetry_mutex);
    hao_free(host);
}

uv_loop_t *hao_runtime_loop(JSContext *ctx) {
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    return host ? host->loop : NULL;
}

static void hao_print_test_failure(JSContext *ctx, JSValueConst error, const char *path);

static int hao_runtime_eval_impl(uintptr_t handle, const char *source, size_t source_len,
                                 const char *filename, size_t filename_len, bool test_file) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (filename_len == SIZE_MAX || source_len == SIZE_MAX) return 1;
    if (hao_package_install(host) != 0) return 1;
    char *name = hao_alloc(filename_len + 1);
    if (!name) return 1;
    memcpy(name, filename, filename_len);
    name[filename_len] = 0;
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__hao_test_filePath", JS_NewStringLen(host->context, filename, filename_len));
    JS_FreeValue(host->context, global);
    char *input = hao_alloc(source_len + 1);
    if (!input) {
        hao_free(name);
        return 1;
    }
    memcpy(input, source, source_len);
    input[source_len] = 0;
    char *transformed = hao_transpile_types_for_path(input, name);
    hao_free(input);
    if (!transformed) {
        char *error = hao_transpiler_last_error();
        if (error) {
            hao_free(host->embed_error);
            host->embed_error = hao_strdup(error);
            if (test_file) fprintf(stderr, "TranspileFailed\n");
            else fprintf(stderr, "%s\n", error);
            hao_transpiler_free(error);
        }
        hao_free(name);
        return test_file ? 2 : 1;
    }
    JSValue result = JS_Eval(host->context, transformed, strlen(transformed), name, JS_EVAL_TYPE_MODULE);
    hao_transpiler_free(transformed);
    hao_free(name);
    int status = 0;
    if (JS_IsException(result)) {
        if (test_file) {
            JSValue error = JS_GetException(host->context);
            hao_print_test_failure(host->context, error, filename);
            JS_FreeValue(host->context, error);
        } else hao_print_exception(host->context);
        status = 1;
    }
    JS_FreeValue(host->context, result);
    return status;
}

int hao_runtime_eval(uintptr_t handle, const char *source, size_t source_len,
                     const char *filename, size_t filename_len) {
    return hao_runtime_eval_impl(handle, source, source_len, filename, filename_len, false);
}

int hao_runtime_eval_test(uintptr_t handle, const char *source, size_t source_len,
                          const char *filename, size_t filename_len) {
    return hao_runtime_eval_impl(handle, source, source_len, filename, filename_len, true);
}

static char *hao_rewrite_cell_declarations(const char *source) {
    size_t length = strlen(source);
    char *output = hao_alloc(length * 2 + 1);
    if (!output) return NULL;
    size_t at = 0;
    const char *line = source;
    while (*line) {
        const char *end = strchr(line, '\n');
        size_t count = end ? (size_t)(end - line) : strlen(line);
        if (count >= 6 && !memcmp(line, "const ", 6)) {
            memcpy(output + at, "var ", 4); at += 4;
            memcpy(output + at, line + 6, count - 6); at += count - 6;
        } else if (count >= 4 && !memcmp(line, "let ", 4)) {
            memcpy(output + at, "var ", 4); at += 4;
            memcpy(output + at, line + 4, count - 4); at += count - 4;
        } else if (count >= 7 && !memcmp(line, "class ", 6)) {
            size_t name_end = 6;
            while (name_end < count && line[name_end] != ' ' && line[name_end] != '{' && line[name_end] != '\t') name_end++;
            if (name_end > 6) {
                memcpy(output + at, "var ", 4); at += 4;
                memcpy(output + at, line + 6, name_end - 6); at += name_end - 6;
                memcpy(output + at, " = ", 3); at += 3;
            }
            memcpy(output + at, line, count); at += count;
        } else {
            memcpy(output + at, line, count); at += count;
        }
        if (end) { output[at++] = '\n'; line = end + 1; }
        else break;
    }
    output[at] = 0;
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
    if (name[0] == '<') {
        char cwd[4096];
        if (!getcwd(cwd, sizeof(cwd))) { hao_free(input); hao_free(name); return NULL; }
        size_t needed = strlen(cwd) + filename_len + 10;
        char *absolute = hao_alloc(needed);
        if (!absolute) { hao_free(input); hao_free(name); return NULL; }
        snprintf(absolute, needed, "%s/.%s.ts", cwd, name);
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

int hao_runtime_start_tests(uintptr_t handle, const char *grep, size_t grep_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__hao_test_grep", JS_NewStringLen(ctx, grep, grep_len));
    JS_FreeValue(ctx, global);
    const char *source = "globalThis.__hao_test_run()";
    JSValue result = JS_Eval(ctx, source, strlen(source), "<hao-test-runner>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        hao_print_exception(ctx);
        JS_FreeValue(ctx, result);
        return 1;
    }
    JS_FreeValue(ctx, result);
    return 0;
}

int hao_runtime_set_test_file_counts(uintptr_t handle, size_t loaded, size_t failed, size_t total) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!host) return 1;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue counts = JS_NewObject(ctx);
    if (JS_IsException(global) || JS_IsException(counts)) {
        JS_FreeValue(ctx, global);
        JS_FreeValue(ctx, counts);
        return 1;
    }
    JS_SetPropertyStr(ctx, counts, "loaded", JS_NewInt64(ctx, (int64_t)loaded));
    JS_SetPropertyStr(ctx, counts, "failed", JS_NewInt64(ctx, (int64_t)failed));
    JS_SetPropertyStr(ctx, counts, "total", JS_NewInt64(ctx, (int64_t)total));
    int status = JS_SetPropertyStr(ctx, global, "__hao_test_file_counts", counts);
    JS_FreeValue(ctx, global);
    return status < 0 ? 1 : 0;
}

int hao_runtime_set_executable(uintptr_t handle, const char *path, size_t path_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    int status = JS_SetPropertyStr(ctx, global, "__hao_test_executablePath", JS_NewStringLen(ctx, path, path_len));
    JS_FreeValue(ctx, global);
    return status < 0 ? 1 : 0;
}

int hao_runtime_test_failures(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue value = JS_GetPropertyStr(ctx, global, "__hao_test_failed");
    int32_t failures = -1;
    if (JS_IsNumber(value)) JS_ToInt32(ctx, &failures, value);
    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, global);
    return failures;
}

static void hao_print_test_failure(JSContext *ctx, JSValueConst error, const char *path) {
    JSValue detail = JS_GetPropertyStr(ctx, error, "message");
    const char *message = JS_IsUndefined(detail) ? JS_ToCString(ctx, error) : JS_ToCString(ctx, detail);
    fprintf(stderr, "%s module %s\n  %s\n",
            hao_test_reporter_ansi() ? "\x1b[31m✕\x1b[0m" : "✕",
            path, message ? message : "[uninitialized]");
    if (message) JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, detail);
}

static int hao_runtime_drain_impl(uintptr_t handle, const char *test_path) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *job_ctx = NULL;
    int result;
    int ran_jobs = 0;
    while ((result = JS_ExecutePendingJob(host->runtime, &job_ctx)) > 0) ran_jobs = 1;
    if (result < 0) {
        if (test_path) {
            JSValue error = JS_GetException(job_ctx);
            hao_print_test_failure(job_ctx, error, test_path);
            JS_FreeValue(job_ctx, error);
        } else hao_print_exception(job_ctx);
        return -1;
    }
    if (host->has_rejection) {
        if (test_path) hao_print_test_failure(host->rejection_context, host->rejection, test_path);
        else hao_print_value(host->rejection_context, host->rejection);
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
        return -1;
    }
    return ran_jobs;
}

int hao_runtime_drain(uintptr_t handle) { return hao_runtime_drain_impl(handle, NULL); }
int hao_runtime_drain_test(uintptr_t handle, const char *path, size_t length) {
    char *name = hao_alloc(length + 1);
    if (!name) return -1;
    memcpy(name, path, length);
    name[length] = 0;
    int result = hao_runtime_drain_impl(handle, name);
    hao_free(name);
    return result;
}

int hao_runtime_run_turn(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    int result = hao_async_uv_run_once(host->loop);
    if (result < 0) return -1;
    if (host->has_callback_error) {
        hao_print_value(host->context, host->callback_error);
        JS_FreeValue(host->context, host->callback_error);
        host->has_callback_error = false;
        return -1;
    }
    return result;
}
