#include "bridge.h"
#include <quickjs.h>
#include "runtime_allocator.h"
#include <uv.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "runtime_host.h"
#include "runtime_internal.h"
#include "test/runner.h"
#include "std/fs/native.h"
#include "std/process/native.h"
#include "std/http/native.h"
#include "std/http/server_uv.h"
#include "std/ffi/native.h"
#include "telemetry/metrics.h"
#include "js/addon_native.h"
#include "errors.h"
#include "global/console.h"

#include "../../libs/transpiler/include/hao_transpiler.h"
void hao_runtime_free(uintptr_t handle);

typedef struct {
    JSValue captured;
    JSValue previous;
} HaoJobTrace;

static JSValue hao_trace_call(JSContext *ctx, const char *name,
                              int argc, JSValueConst *argv) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue function = JS_GetPropertyStr(ctx, global, name);
    JSValue result = JS_UNDEFINED;
    if (JS_IsFunction(ctx, function)) result = JS_Call(ctx, function, global, argc, argv);
    JS_FreeValue(ctx, function);
    JS_FreeValue(ctx, global);
    return result;
}

static void *hao_job_trace_capture(JSContext *ctx, void *opaque) {
    (void)opaque;
    JSValue context = hao_trace_call(ctx, "__hao_telemetry_captureContext", 0, NULL);
    if (!JS_IsObject(context)) {
        JS_FreeValue(ctx, context);
        return NULL;
    }
    JSValue span = JS_GetPropertyStr(ctx, context, "span");
    bool active = !JS_IsNull(span) && !JS_IsUndefined(span);
    JS_FreeValue(ctx, span);
    if (!active) {
        JS_FreeValue(ctx, context);
        return NULL;
    }
    HaoJobTrace *trace = malloc(sizeof(*trace));
    if (!trace) {
        JS_FreeValue(ctx, context);
        return NULL;
    }
    trace->captured = context;
    trace->previous = JS_UNDEFINED;
    return trace;
}

static void hao_job_trace_enter(JSContext *ctx, void *job_context, void *opaque) {
    (void)opaque;
    HaoJobTrace *trace = job_context;
    trace->previous = hao_trace_call(ctx, "__hao_telemetry_enterContext", 1, &trace->captured);
}

static void hao_job_trace_leave(JSContext *ctx, void *job_context, void *opaque) {
    (void)opaque;
    HaoJobTrace *trace = job_context;
    if (JS_IsObject(trace->previous)) {
        JSValue restored = hao_trace_call(ctx, "__hao_telemetry_enterContext", 1, &trace->previous);
        JS_FreeValue(ctx, restored);
    }
}

static void hao_job_trace_release(JSRuntime *rt, void *job_context, void *opaque) {
    (void)opaque;
    HaoJobTrace *trace = job_context;
    JS_FreeValueRT(rt, trace->captured);
    JS_FreeValueRT(rt, trace->previous);
    free(trace);
}

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

void hao_runtime_print_value(JSContext *ctx, JSValueConst error) {
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

void hao_runtime_print_exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    hao_runtime_print_value(ctx, error);
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

uintptr_t hao_runtime_new(size_t stack_size, size_t gc_threshold, size_t thread_pool_size,
                          size_t trace_records, int console_enabled) {
    if (console_enabled && trace_records > 1048576) {
        fprintf(stderr, "error: TelemetryTraceLimitExceeded\n");
        return 0;
    }
    if (thread_pool_size) {
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
    if (gc_threshold) JS_SetGCThreshold(host->runtime, gc_threshold);
    JS_SetHostPromiseRejectionTracker(host->runtime, hao_on_rejection, host);
    JS_SetJobContextHooks(host->runtime, hao_job_trace_capture, hao_job_trace_enter,
                          hao_job_trace_leave, hao_job_trace_release, host);
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
        hao_runtime_print_exception(host->context);
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
            hao_test_print_failure(host->context, error, filename);
            JS_FreeValue(host->context, error);
        } else hao_runtime_print_exception(host->context);
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

int hao_runtime_drain(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *job_ctx = NULL;
    int result;
    int ran_jobs = 0;
    while ((result = JS_ExecutePendingJob(host->runtime, &job_ctx)) > 0) ran_jobs = 1;
    if (result < 0) {
        hao_runtime_print_exception(job_ctx);
        return -1;
    }
    if (host->has_rejection) {
        hao_runtime_print_value(host->rejection_context, host->rejection);
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
        return -1;
    }
    return ran_jobs;
}

int hao_runtime_run_turn(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    int result = hao_async_uv_run_once(host->loop);
    if (result < 0) return -1;
    if (host->has_callback_error) {
        hao_runtime_print_value(host->context, host->callback_error);
        JS_FreeValue(host->context, host->callback_error);
        host->has_callback_error = false;
        return -1;
    }
    return result;
}
