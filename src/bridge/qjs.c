#include "cyna_exports.h"
#include "runtime.h"
#include "support.h"
#include "telemetry.h"
#include "../../libs/transpiler/include/hao_transpiler.h"
#include "../../include/hao.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <ctype.h>
#include <ffi/ffi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <limits.h>
#include <math.h>
#include <openssl/evp.h>
#include <quickjs.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <uv.h>

/* Cyna exports called back through this translation unit. */
int hao_install_runtime_error(void *ctx);
int hao_http_valid_method(const unsigned char *method);
int hao_http_url_error(const unsigned char *url);
unsigned char *hao_http_transport_url(const unsigned char *url);
int hao_http_server_limits_error(double port, double max_connections, double timeout_ms);
int hao_ffi_type_code(const unsigned char *name);
int hao_ffi_parse_unsigned(const unsigned char *text, size_t length, uint64_t *output);
size_t hao_jupyter_rewrite_cell(const unsigned char *source, size_t length,
                                unsigned char *output, size_t capacity);

/* Single-unit phases are forward declared for runtime initialization. */
void hao_install_fs_globals(JSContext *ctx, JSValue global);
void hao_install_process_globals(JSContext *ctx, JSValue global);
void hao_install_http_globals(JSContext *ctx, JSValue global);
void hao_install_http_server_globals(JSContext *ctx, JSValue global);
void hao_install_ffi_globals(JSContext *ctx, JSValue global);
void hao_http_server_cleanup(JSContext *ctx);
void hao_ffi_cleanup(JSContext *ctx);
void hao_addon_cleanup(JSContext *ctx);
void hao_cleanup_timers(HaoRuntime *host);
JSModuleDef *hao_load_addon(JSContext *ctx, const char *name);
void hao_test_print_failure(JSContext *ctx, JSValueConst error, const char *path);

/* Runtime lifetime, evaluation, and errors. */
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

/* Module loading and package callbacks. */
static HaoSourceModule *hao_find_module(HaoRuntime *host, const char *name) {
    for (HaoSourceModule *module = host->modules; module; module = module->next) {
        if (strcmp(module->name, name) == 0) return module;
    }
    return NULL;
}

static HaoNativeModule *hao_find_native_module(HaoRuntime *host, const char *name) {
    for (HaoNativeModule *module = host->native_modules; module; module = module->next) {
        if (strcmp(module->name, name) == 0) return module;
    }
    return NULL;
}

int hao_runtime_register(uintptr_t handle, const char *name, size_t name_len,
                         const char *source, size_t source_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!name_len || name_len == SIZE_MAX || source_len == SIZE_MAX ||
        memchr(name, 0, name_len)) return 1;
    HaoSourceModule *module = hao_calloc(1, sizeof(*module));
    if (!module) return 1;
    module->name = hao_alloc(name_len + 1);
    module->source = hao_alloc(source_len + 1);
    if (!module->name || !module->source) {
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        return 1;
    }
    memcpy(module->name, name, name_len);
    module->name[name_len] = 0;
    if (source_len) memcpy(module->source, source, source_len);
    module->source[source_len] = 0;
    module->source_len = source_len;
    if (hao_find_module(host, module->name) || hao_find_native_module(host, module->name)) {
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        return 1;
    }
    module->next = host->modules;
    host->modules = module;
    return 0;
}

int hao_runtime_register_native(uintptr_t handle, const char *name, size_t name_len,
                                void *(*load)(void *, const char *)) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!name_len || name_len == SIZE_MAX || !load || memchr(name, 0, name_len)) return 1;
    HaoNativeModule *module = hao_calloc(1, sizeof(*module));
    if (!module) return 1;
    module->name = hao_strndup(name, name_len);
    if (!module->name || hao_find_module(host, module->name) ||
        hao_find_native_module(host, module->name)) {
        hao_free(module->name);
        hao_free(module);
        return 1;
    }
    module->load = load;
    module->next = host->native_modules;
    host->native_modules = module;
    return 0;
}

int hao_embed_register_native_module(HaoRuntimeHandle handle, const unsigned char *name,
                                     size_t name_len, HaoNativeModuleLoader loader) {
    if (!handle) return 1;
    if (!name && name_len) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    if (hao_runtime_register_native(handle, (const char *)name, name_len, loader) == 0) return 0;
    static const unsigned char failure[] = "Native module registration failed";
    hao_embed_set_error(handle, failure, sizeof(failure) - 1);
    return 1;
}

int hao_embed_register_package_callbacks(HaoRuntimeHandle handle, const unsigned char *name,
                                         size_t name_len, HaoPackageInstall install,
                                         HaoPackageDeinit deinit, void *userdata) {
    if (!handle) return 1;
    if (!name && name_len) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    HaoRuntime *host = (HaoRuntime *)handle;
    bool valid = name_len && name_len != SIZE_MAX && !memchr(name, 0, name_len);
    for (HaoPackageCallbacks *it = host->packages; valid && it; it = it->next) {
        if (strlen(it->name) == name_len && memcmp(it->name, name, name_len) == 0) valid = false;
    }
    HaoPackageCallbacks *entry = valid ? hao_calloc(1, sizeof(*entry)) : NULL;
    if (entry) entry->name = hao_strndup((const char *)name, name_len);
    if (!entry || !entry->name) {
        if (entry) { hao_free(entry->name); hao_free(entry); }
        static const unsigned char failure[] = "Package registration failed";
        hao_embed_set_error(handle, failure, sizeof(failure) - 1);
        return 1;
    }
    entry->install = install;
    entry->deinit = deinit;
    entry->userdata = userdata;
    entry->prev = host->last_package;
    if (host->last_package) host->last_package->next = entry;
    else host->packages = entry;
    host->last_package = entry;
    return 0;
}

static bool hao_package_owns(const unsigned char *package_name, size_t package_len,
                             const unsigned char *specifier, size_t specifier_len) {
    if (!specifier || !specifier_len || memchr(specifier, 0, specifier_len)) return false;
    bool standard = package_len == 3 && memcmp(package_name, "std", 3) == 0;
    if (standard) return specifier_len >= 4 && memcmp(specifier, "std:", 4) == 0;
    if (specifier_len >= 4 && memcmp(specifier, "std:", 4) == 0) return false;
    return specifier_len >= package_len && memcmp(specifier, package_name, package_len) == 0 &&
        (specifier_len == package_len || specifier[package_len] == ':');
}

static bool hao_same_name(const unsigned char *left, size_t left_len,
                          const unsigned char *right, size_t right_len) {
    return left_len == right_len && memcmp(left, right, left_len) == 0;
}

static void hao_rollback_package_modules(HaoRuntime *host, size_t source_count,
                                          size_t native_count) {
    while (source_count--) {
        HaoSourceModule *module = host->modules;
        host->modules = module->next;
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
    }
    while (native_count--) {
        HaoNativeModule *module = host->native_modules;
        host->native_modules = module->next;
        hao_free(module->name);
        hao_free(module);
    }
}

int hao_embed_register_package(HaoRuntimeHandle handle, const HaoEmbedPackage *package) {
    if (!handle || !package) return 1;
    if ((!package->name && package->name_len) ||
        (package->source_count && !package->sources) ||
        (package->native_count && !package->native_modules)) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    HaoRuntime *host = (HaoRuntime *)handle;
    bool valid = package->name_len && package->name_len != SIZE_MAX &&
        !memchr(package->name, 0, package->name_len);
    for (HaoPackageCallbacks *it = host->packages; valid && it; it = it->next) {
        if (strlen(it->name) == package->name_len &&
            memcmp(it->name, package->name, package->name_len) == 0) valid = false;
    }
    for (size_t i = 0; valid && i < package->source_count; i++) {
        const HaoEmbedSourceModule *source = &package->sources[i];
        valid = source->specifier_len != SIZE_MAX && source->source_len != SIZE_MAX &&
            (source->source || !source->source_len) &&
            hao_package_owns(package->name, package->name_len,
                             source->specifier, source->specifier_len);
        if (!valid) break;
        for (size_t j = 0; j < i; j++) {
            const HaoEmbedSourceModule *prior = &package->sources[j];
            if (hao_same_name(source->specifier, source->specifier_len,
                              prior->specifier, prior->specifier_len)) valid = false;
        }
        for (size_t j = 0; j < package->native_count; j++) {
            const HaoEmbedNativeModule *native = &package->native_modules[j];
            if (native->specifier && hao_same_name(source->specifier, source->specifier_len,
                native->specifier, native->specifier_len)) valid = false;
        }
        char *name = valid ? hao_strndup((const char *)source->specifier, source->specifier_len) : NULL;
        if (!name || hao_find_module(host, name) || hao_find_native_module(host, name)) valid = false;
        hao_free(name);
    }
    for (size_t i = 0; valid && i < package->native_count; i++) {
        const HaoEmbedNativeModule *native = &package->native_modules[i];
        valid = native->specifier_len != SIZE_MAX && native->loader &&
            hao_package_owns(package->name, package->name_len,
                             native->specifier, native->specifier_len);
        if (!valid) break;
        for (size_t j = 0; j < i; j++) {
            const HaoEmbedNativeModule *prior = &package->native_modules[j];
            if (hao_same_name(native->specifier, native->specifier_len,
                              prior->specifier, prior->specifier_len)) valid = false;
        }
        char *name = valid ? hao_strndup((const char *)native->specifier, native->specifier_len) : NULL;
        if (!name || hao_find_module(host, name) || hao_find_native_module(host, name)) valid = false;
        hao_free(name);
    }
    size_t added_sources = 0, added_native = 0;
    for (size_t i = 0; valid && i < package->source_count; i++) {
        const HaoEmbedSourceModule *source = &package->sources[i];
        valid = hao_runtime_register(handle, (const char *)source->specifier, source->specifier_len,
                                     (const char *)source->source, source->source_len) == 0;
        if (valid) added_sources++;
    }
    for (size_t i = 0; valid && i < package->native_count; i++) {
        const HaoEmbedNativeModule *native = &package->native_modules[i];
        valid = hao_runtime_register_native(handle, (const char *)native->specifier,
                                            native->specifier_len, native->loader) == 0;
        if (valid) added_native++;
    }
    if (valid) valid = hao_embed_register_package_callbacks(handle, package->name,
        package->name_len, package->install, package->deinit, package->userdata) == 0;
    if (valid) return 0;
    hao_rollback_package_modules(host, added_sources, added_native);
    hao_embed_clear_error(handle);
    static const unsigned char failure[] = "Package registration failed";
    hao_embed_set_error(handle, failure, sizeof(failure) - 1);
    return 1;
}

int hao_package_install(HaoRuntime *host) {
    for (HaoPackageCallbacks *entry = host->packages; entry; entry = entry->next) {
        if (entry->install && entry->install((uintptr_t)host, entry->userdata) != 0) {
            static const unsigned char failure[] = "Package installation failed";
            hao_embed_set_error((uintptr_t)host, failure, sizeof(failure) - 1);
            return 1;
        }
    }
    return 0;
}

void hao_package_cleanup(HaoRuntime *host) {
    HaoPackageCallbacks *entry = host->last_package;
    while (entry) {
        HaoPackageCallbacks *previous = entry->prev;
        if (entry->deinit) entry->deinit((uintptr_t)host, entry->userdata);
        hao_free(entry->name);
        hao_free(entry);
        entry = previous;
    }
    host->packages = host->last_package = NULL;
}

char *hao_normalize_module(JSContext *ctx, const char *base,
                                   const char *specifier, void *opaque) {
    HaoRuntime *host = opaque;
    if (hao_find_module(host, specifier) || hao_find_native_module(host, specifier)) {
        size_t len = strlen(specifier);
        char *normalized = js_malloc(ctx, len + 1);
        if (normalized) memcpy(normalized, specifier, len + 1);
        return normalized;
    }
    if (strncmp(specifier, "./", 2) != 0 && strncmp(specifier, "../", 3) != 0) {
        unsigned char candidate[4096];
        int candidate_len = hao_resolve_package((const unsigned char *)base,
                                                (const unsigned char *)specifier,
                                                candidate, sizeof(candidate));
        if (candidate_len < 0) {
            const char *reason = candidate_len == -2 ? "CommonJS packages are not supported"
                : candidate_len == -3 ? "Package entry is not ESM-compatible"
                : candidate_len == -4 ? "Package manifest not found"
                : candidate_len == -5 ? "Package export not found"
                : "Cannot resolve module";
            JS_ThrowReferenceError(ctx, "%s: %s (from %s)", reason, specifier, base);
            return NULL;
        }
        candidate[candidate_len] = 0;
        char *resolved = (char *)hao_module_lexical_absolute(candidate);
        if (!resolved) {
            JS_ThrowReferenceError(ctx, "Package entry not found: %s", specifier);
            return NULL;
        }
        size_t len = hao_addon_name_length((const unsigned char *)specifier,
                                           (const unsigned char *)resolved);
        char *normalized = js_malloc(ctx, len + 1);
        if (normalized && hao_addon_write_name((const unsigned char *)specifier,
                (const unsigned char *)resolved, (unsigned char *)normalized, len + 1) != 0) {
            js_free(ctx, normalized);
            normalized = NULL;
        }
        hao_free(resolved);
        return normalized;
    }
    char *resolved = (char *)hao_module_relative((const unsigned char *)base,
                                                  (const unsigned char *)specifier);
    if (!resolved) {
        JS_ThrowReferenceError(ctx, "Module not found: %s", specifier);
        return NULL;
    }
    size_t len = strlen(resolved);
    char *normalized = js_malloc(ctx, len + 1);
    if (normalized) memcpy(normalized, resolved, len + 1);
    hao_free(resolved);
    return normalized;
}

JSModuleDef *hao_load_module(JSContext *ctx, const char *name, void *opaque) {
    if (strncmp(name, "addon:", 6) == 0) return hao_load_addon(ctx, name);
    HaoRuntime *host = opaque;
    HaoNativeModule *native = hao_find_native_module(host, name);
    if (native) return native->load(ctx, name);
    HaoSourceModule *module = hao_find_module(host, name);
    if (module) {
        size_t name_len = strlen(name);
        char *typescript_path = hao_alloc(name_len + 4);
        if (!typescript_path) return NULL;
        memcpy(typescript_path, name, name_len);
        memcpy(typescript_path + name_len, ".ts", 4);
        char *transformed = hao_transpile_types_for_path(module->source, typescript_path);
        hao_free(typescript_path);
        if (!transformed) {
            char *error = hao_transpiler_last_error();
            JS_ThrowSyntaxError(ctx, "%s", error ? error : "Module transpilation failed");
            if (error) hao_transpiler_free(error);
            return NULL;
        }
        JSValue compiled = JS_Eval(ctx, transformed, strlen(transformed), name,
                                   JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        hao_transpiler_free(transformed);
        if (JS_IsException(compiled)) return NULL;
        JSModuleDef *result = JS_VALUE_GET_PTR(compiled);
        JS_FreeValue(ctx, compiled);
        return result;
    }
    char *source = (char *)hao_fs_read_alloc((const unsigned char *)name,
                                             strlen(name), 10 * 1024 * 1024);
    if (!source) {
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    char *transformed = hao_transpile_types_for_path(source, name);
    hao_free(source);
    if (!transformed) {
        char *error = hao_transpiler_last_error();
        JS_ThrowSyntaxError(ctx, "%s", error ? error : "Module transpilation failed");
        if (error) hao_transpiler_free(error);
        return NULL;
    }
    JSValue compiled = JS_Eval(ctx, transformed, strlen(transformed), name,
                               JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    hao_transpiler_free(transformed);
    if (JS_IsException(compiled)) return NULL;
    JSModuleDef *compiled_module = JS_VALUE_GET_PTR(compiled);
    JS_FreeValue(ctx, compiled);
    return compiled_module;
}

void hao_module_cleanup(HaoRuntime *host) {
    HaoSourceModule *module = host->modules;
    while (module) {
        HaoSourceModule *next = module->next;
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        module = next;
    }
    HaoNativeModule *native = host->native_modules;
    while (native) {
        HaoNativeModule *next = native->next;
        hao_free(native->name);
        hao_free(native);
        native = next;
    }
}

/* JavaScript runtime error installation. */
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

int hao_error_eval(void *context, const unsigned char *source, size_t length) {
    JSContext *ctx = context;
    JSValue result = JS_Eval(ctx, (const char *)source, length, "<runtime-errors>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        JS_FreeValue(ctx, result);
        return -1;
    }
    JS_FreeValue(ctx, result);
    return 0;
}

void hao_error_install_stack_capture(void *context) {
    JSContext *ctx = context;
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__hao_capture_native_stack",
        JS_NewCFunction(ctx, capture_native_stack, "captureNativeStack", 1));
    JS_FreeValue(ctx, global);
}

/* Console installation and test output. */
int hao_test_reporter_ansi(void) {
    const char *mode = getenv("RUNTIME_TEST_REPORTER");
    return !mode || strcasecmp(mode, "plain") != 0;
}

void hao_test_print_load(size_t index, size_t total, const unsigned char *path, size_t length) {
    if (hao_test_reporter_ansi()) fputs("\x1b[36m→\x1b[0m", stderr);
    else fputs("→", stderr);
    fprintf(stderr, " Load [%zu/%zu] ", index, total);
    fwrite(path, 1, length, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

static int hao_capture_append(char **buffer, size_t *length, size_t *capacity,
                              const char *text, size_t count) {
    if (count > SIZE_MAX - *length) return -1;
    if (*length + count > *capacity) {
        size_t next_capacity = *capacity ? *capacity : 256;
        while (next_capacity < *length + count) {
            if (next_capacity > SIZE_MAX / 2) {
                next_capacity = *length + count;
                break;
            }
            next_capacity *= 2;
        }
        char *next = hao_realloc(*buffer, next_capacity);
        if (!next) return -1;
        *buffer = next;
        *capacity = next_capacity;
    }
    memcpy(*buffer + *length, text, count);
    *length += count;
    return 0;
}

static JSValue hao_console_write(JSContext *ctx, int argc, JSValueConst *argv, int target) {
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    FILE *stream = target == 1 ? stdout : stderr;
    bool capture = host->capture_active && (host->capture_target == target || host->capture_target == 3);
    char **buffer = target == 1 ? &host->capture_stdout : &host->capture_stderr;
    size_t *length = target == 1 ? &host->capture_stdout_len : &host->capture_stderr_len;
    size_t *capacity = target == 1 ? &host->capture_stdout_cap : &host->capture_stderr_cap;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue inspect = JS_GetPropertyStr(ctx, global, "__hao_console_inspect");
    JS_FreeValue(ctx, global);
    for (int i = 0; i < argc; ++i) {
        if (i) {
            if (capture) {
                if (hao_capture_append(buffer, length, capacity, " ", 1) != 0) {
                    JS_FreeValue(ctx, inspect);
                    return JS_ThrowOutOfMemory(ctx);
                }
            } else fputc(' ', stream);
        }
        JSValue formatted = JS_IsFunction(ctx, inspect)
            ? JS_Call(ctx, inspect, JS_UNDEFINED, 1, &argv[i]) : JS_DupValue(ctx, argv[i]);
        if (JS_IsException(formatted)) { JS_FreeValue(ctx, inspect); return JS_EXCEPTION; }
        size_t text_length = 0;
        const char *text = JS_ToCStringLen(ctx, &text_length, formatted);
        if (!text) { JS_FreeValue(ctx, formatted); JS_FreeValue(ctx, inspect); return JS_EXCEPTION; }
        if (capture) {
            int status = hao_capture_append(buffer, length, capacity, text, text_length);
            JS_FreeCString(ctx, text);
            JS_FreeValue(ctx, formatted);
            if (status != 0) { JS_FreeValue(ctx, inspect); return JS_ThrowOutOfMemory(ctx); }
        } else {
            fwrite(text, 1, text_length, stream);
            JS_FreeCString(ctx, text);
            JS_FreeValue(ctx, formatted);
        }
    }
    JS_FreeValue(ctx, inspect);
    if (capture) {
        if (hao_capture_append(buffer, length, capacity, "\n", 1) != 0) return JS_ThrowOutOfMemory(ctx);
    } else {
        fputc('\n', stream);
        fflush(stream);
    }
    return JS_UNDEFINED;
}

static JSValue hao_console_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return hao_console_write(ctx, argc, argv, 1);
}

static JSValue hao_console_error(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return hao_console_write(ctx, argc, argv, 2);
}

static JSValue hao_test_report(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, argv[0]);
    if (!text) return JS_EXCEPTION;
    fwrite(text, 1, length, stderr);
    fflush(stderr);
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}

static JSValue hao_begin_capture(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (host->capture_active) return JS_ThrowInternalError(ctx, "captureOutput does not support nested captures");
    const char *target = argc ? JS_ToCString(ctx, argv[0]) : NULL;
    int kind = !target || strcmp(target, "stdout") == 0 ? 1
        : strcmp(target, "stderr") == 0 ? 2
        : strcmp(target, "both") == 0 ? 3 : 0;
    if (target) JS_FreeCString(ctx, target);
    if (!kind) return JS_ThrowTypeError(ctx, "captureOutput target must be 'stdout', 'stderr', or 'both'");
    host->capture_stdout_len = 0;
    host->capture_stderr_len = 0;
    host->capture_target = kind;
    host->capture_active = true;
    return JS_UNDEFINED;
}

static JSValue hao_end_capture(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (!host->capture_active) return JS_ThrowInternalError(ctx, "captureOutput end called without an active capture");
    host->capture_active = false;
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "stdout", JS_NewStringLen(ctx, host->capture_stdout, host->capture_stdout_len));
    JS_SetPropertyStr(ctx, result, "stderr", JS_NewStringLen(ctx, host->capture_stderr, host->capture_stderr_len));
    if (host->capture_stdout_len > SIZE_MAX - host->capture_stderr_len) {
        JS_FreeValue(ctx, result);
        return JS_ThrowOutOfMemory(ctx);
    }
    size_t total = host->capture_stdout_len + host->capture_stderr_len;
    char *combined = hao_alloc(total ? total : 1);
    if (!combined) { JS_FreeValue(ctx, result); return JS_ThrowOutOfMemory(ctx); }
    if (host->capture_stdout_len) memcpy(combined, host->capture_stdout, host->capture_stdout_len);
    if (host->capture_stderr_len) memcpy(combined + host->capture_stdout_len, host->capture_stderr, host->capture_stderr_len);
    JS_SetPropertyStr(ctx, result, "combined", JS_NewStringLen(ctx, combined, total));
    hao_free(combined);
    return result;
}

void hao_install_console_globals(JSContext *ctx, JSValue global) {
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log", JS_NewCFunction(ctx, hao_console_log, "log", 1));
    JS_SetPropertyStr(ctx, console, "error", JS_NewCFunction(ctx, hao_console_error, "error", 1));
    JS_SetPropertyStr(ctx, console, "warn", JS_NewCFunction(ctx, hao_console_error, "warn", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_SetPropertyStr(ctx, global, "__hao_test_beginCapture", JS_NewCFunction(ctx, hao_begin_capture, "beginCapture", 1));
    JS_SetPropertyStr(ctx, global, "__hao_test_endCapture", JS_NewCFunction(ctx, hao_end_capture, "endCapture", 0));
    JS_SetPropertyStr(ctx, global, "__hao_test_report", JS_NewCFunction(ctx, hao_test_report, "report", 1));
}

int hao_global_install_console(uintptr_t handle) {
    if (!handle) return 1;
    HaoRuntime *host = (HaoRuntime *)handle;
    JSValue global = JS_GetGlobalObject(host->context);
    if (JS_IsException(global)) return 1;
    hao_install_console_globals(host->context, global);
    JS_FreeValue(host->context, global);
    return 0;
}

/* Timer globals. */
struct HaoTimer {
    uv_timer_t handle;
    HaoRuntime *host;
    JSValue callback;
    JSValue trace_context;
    uint32_t id;
    HaoTimer *next;
};

static void hao_unlink_timer(HaoRuntime *host, HaoTimer *timer) {
    HaoTimer **link = &host->timers;
    while (*link) {
        if (*link == timer) {
            *link = timer->next;
            return;
        }
        link = &(*link)->next;
    }
}

static void hao_timer_closed(uv_handle_t *handle) {
    HaoTimer *timer = handle->data;
    hao_free(timer);
}

static JSValue hao_enter_trace_context(JSContext *ctx, JSValueConst context) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue enter = JS_GetPropertyStr(ctx, global, "__hao_telemetry_enterContext");
    JSValue previous = JS_UNDEFINED;
    if (JS_IsFunction(ctx, enter)) previous = JS_Call(ctx, enter, global, 1, &context);
    JS_FreeValue(ctx, enter);
    JS_FreeValue(ctx, global);
    return previous;
}

static void hao_retain_timer_error(HaoRuntime *host, JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    if (!host->has_callback_error) {
        host->callback_error = error;
        host->has_callback_error = true;
    } else JS_FreeValue(ctx, error);
}

static void hao_timer_fired(uv_timer_t *handle) {
    HaoTimer *timer = handle->data;
    HaoRuntime *host = timer->host;
    hao_unlink_timer(host, timer);
    JSValue previous = JS_UNDEFINED;
    if (!JS_IsUndefined(timer->trace_context)) previous = hao_enter_trace_context(host->context, timer->trace_context);
    JSValue result = JS_Call(host->context, timer->callback, JS_UNDEFINED, 0, NULL);
    if (JS_IsException(result)) {
        hao_retain_timer_error(host, host->context);
    }
    if (host->has_callback_error || host->has_rejection) uv_stop(host->loop);
    if (!JS_IsUndefined(previous)) {
        JSValue restored = hao_enter_trace_context(host->context, previous);
        JS_FreeValue(host->context, restored);
    }
    JS_FreeValue(host->context, previous);
    JS_FreeValue(host->context, result);
    JS_FreeValue(host->context, timer->callback);
    JS_FreeValue(host->context, timer->trace_context);
    uv_close((uv_handle_t *)handle, hao_timer_closed);
}

static JSValue hao_set_timeout(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "setTimeout requires a callback");
    }
    int64_t delay = 0;
    if (argc >= 2 && JS_ToInt64(ctx, &delay, argv[1]) < 0) return JS_EXCEPTION;
    if (delay < 0) delay = 0;
    HaoTimer *timer = hao_calloc(1, sizeof(*timer));
    if (!timer) return JS_ThrowOutOfMemory(ctx);
    if (uv_timer_init(host->loop, &timer->handle) != 0) {
        hao_free(timer);
        return JS_ThrowInternalError(ctx, "Timer initialization failed");
    }
    timer->host = host;
    timer->handle.data = timer;
    timer->callback = JS_DupValue(ctx, argv[0]);
    timer->trace_context = JS_UNDEFINED;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue capture = JS_GetPropertyStr(ctx, global, "__hao_telemetry_captureContext");
    if (JS_IsFunction(ctx, capture)) {
        JSValue context = JS_Call(ctx, capture, global, 0, NULL);
        if (JS_IsObject(context)) {
            JSValue span = JS_GetPropertyStr(ctx, context, "span");
            if (!JS_IsNull(span) && !JS_IsUndefined(span)) timer->trace_context = context;
            else JS_FreeValue(ctx, context);
            JS_FreeValue(ctx, span);
        } else JS_FreeValue(ctx, context);
    }
    JS_FreeValue(ctx, capture);
    JS_FreeValue(ctx, global);
    timer->id = host->next_timer_id++;
    if (host->next_timer_id == 0 || host->next_timer_id > INT32_MAX) host->next_timer_id = 1;
    timer->next = host->timers;
    host->timers = timer;
    if (uv_timer_start(&timer->handle, hao_timer_fired, delay == 0 ? 1 : (uint64_t)delay, 0) != 0) {
        hao_unlink_timer(host, timer);
        JS_FreeValue(ctx, timer->callback);
        JS_FreeValue(ctx, timer->trace_context);
        uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
        return JS_ThrowInternalError(ctx, "Timer scheduling failed");
    }
    return JS_NewInt32(ctx, (int32_t)timer->id);
}

static JSValue hao_clear_timeout(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    int32_t id = 0;
    if (JS_ToInt32(ctx, &id, argv[0]) < 0) {
        JSValue error = JS_GetException(ctx);
        JS_FreeValue(ctx, error);
        return JS_UNDEFINED;
    }
    if (id <= 0) return JS_UNDEFINED;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    for (HaoTimer *timer = host->timers; timer; timer = timer->next) {
        if (timer->id == (uint32_t)id) {
            hao_unlink_timer(host, timer);
            uv_timer_stop(&timer->handle);
            JS_FreeValue(ctx, timer->callback);
            JS_FreeValue(ctx, timer->trace_context);
            uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
            break;
        }
    }
    return JS_UNDEFINED;
}

void hao_install_timer_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "setTimeout", JS_NewCFunction(ctx, hao_set_timeout, "setTimeout", 2));
    JS_SetPropertyStr(ctx, global, "clearTimeout", JS_NewCFunction(ctx, hao_clear_timeout, "clearTimeout", 1));
}

int hao_global_install_timer(uintptr_t handle) {
    if (!handle) return 1;
    HaoRuntime *host = (HaoRuntime *)handle;
    JSValue global = JS_GetGlobalObject(host->context);
    if (JS_IsException(global)) return 1;
    hao_install_timer_globals(host->context, global);
    JS_FreeValue(host->context, global);
    return 0;
}

void hao_cleanup_timers(HaoRuntime *host) {
    while (host->timers) {
        HaoTimer *timer = host->timers;
        hao_unlink_timer(host, timer);
        uv_timer_stop(&timer->handle);
        JS_FreeValue(host->context, timer->callback);
        JS_FreeValue(host->context, timer->trace_context);
        uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
    }
}

/* Native addon ABI. */
typedef struct AddonLibrary {
    JSContext *ctx;
    char *path;
    void *handle;
    const JsModule **modules;
    size_t count;
    struct AddonLibrary *next;
} AddonLibrary;

typedef struct AddonFrame {
    JSContext *ctx;
    int argc;
    const JSValueConst *argv;
    JSValue *owned;
    size_t count;
    char **strings;
    size_t string_count;
} AddonFrame;

static AddonLibrary *libraries;
static bool frame_value(AddonFrame *frame, JsValue handle, JSValueConst *value) {
    if (handle == 0) { *value = JS_UNDEFINED; return true; }
    if (handle <= (size_t)frame->argc) { *value = frame->argv[handle - 1]; return true; }
    size_t index = handle - (size_t)frame->argc - 1;
    if (index >= frame->count) return false;
    *value = frame->owned[index];
    return true;
}

static JsValue frame_push(AddonFrame *frame, JSValue value) {
    JSValue *values = hao_realloc(frame->owned, (frame->count + 1) * sizeof(*values));
    if (!values) {
        JS_FreeValue(frame->ctx, value);
        JS_ThrowOutOfMemory(frame->ctx);
        return 0;
    }
    frame->owned = values;
    frame->owned[frame->count++] = value;
    return (size_t)frame->argc + frame->count;
}

static AddonFrame *frame_of(JsContext *ctx) { return ctx->data; }
static JsValue api_undefined(JsContext *ctx) { return frame_push(frame_of(ctx), JS_UNDEFINED); }
static JsValue api_null(JsContext *ctx) { return frame_push(frame_of(ctx), JS_NULL); }
static JsValue api_bool(JsContext *ctx, int v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewBool(f->ctx, v)); }
static JsValue api_int(JsContext *ctx, int32_t v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewInt32(f->ctx, v)); }
static JsValue api_float(JsContext *ctx, double v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewFloat64(f->ctx, v)); }
static JsValue api_string(JsContext *ctx, const char *v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewString(f->ctx, v)); }
static int api_to_bool(JsContext *ctx, JsValue v, int *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; int result = JS_ToBool(f->ctx, value); if (result < 0) return -1; *out = result; return 0; }
static int api_to_int(JsContext *ctx, JsValue v, int32_t *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; return JS_ToInt32(f->ctx, out, value); }
static int api_to_float(JsContext *ctx, JsValue v, double *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; return JS_ToFloat64(f->ctx, out, value); }
static const char *api_to_string(JsContext *ctx, JsValue v) {
    AddonFrame *f = frame_of(ctx);
    JSValueConst value;
    if (!frame_value(f, v, &value)) return NULL;
    const char *text = JS_ToCString(f->ctx, value);
    if (!text) return NULL;
    char *copy = hao_strdup(text);
    JS_FreeCString(f->ctx, text);
    if (!copy) return NULL;
    char **strings = hao_realloc(f->strings, (f->string_count + 1) * sizeof(*strings));
    if (!strings) { hao_free(copy); return NULL; }
    f->strings = strings;
    f->strings[f->string_count++] = copy;
    return copy;
}
static JsValue api_type_error(JsContext *ctx, const char *message) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_ThrowTypeError(f->ctx, "%s", message)); }
static JsValue api_error(JsContext *ctx, const char *message) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_ThrowInternalError(f->ctx, "%s", message)); }
static JsValue api_object(JsContext *ctx) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewObject(f->ctx)); }
static int api_set(JsContext *ctx, JsValue object, const char *key, JsValue value) { AddonFrame *f = frame_of(ctx); JSValueConst target, item; if (!frame_value(f, object, &target) || !frame_value(f, value, &item)) return -1; return JS_DefinePropertyValueStr(f->ctx, target, key, JS_DupValue(f->ctx, item), JS_PROP_HAS_VALUE | JS_PROP_HAS_ENUMERABLE | JS_PROP_ENUMERABLE); }
static JsValue api_get(JsContext *ctx, JsValue object, const char *key) { AddonFrame *f = frame_of(ctx); JSValueConst target; if (!frame_value(f, object, &target)) return frame_push(f, JS_ThrowInternalError(f->ctx, "invalid object handle")); return frame_push(f, JS_GetPropertyStr(f->ctx, target, key)); }
static int api_is_undefined(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsUndefined(value); }
static int api_is_null(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsNull(value); }
static int api_is_object(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsObject(value); }
static int api_is_array(JsContext *ctx, JsValue v) { AddonFrame *f = frame_of(ctx); JSValueConst value; return frame_value(f, v, &value) && JS_IsArray(value); }
static int api_is_function(JsContext *ctx, JsValue v) { AddonFrame *f = frame_of(ctx); JSValueConst value; return frame_value(f, v, &value) && JS_IsFunction(f->ctx, value); }
static int api_array_length(JsContext *ctx, JsValue v, uint32_t *out) {
    AddonFrame *f = frame_of(ctx);
    JSValueConst array;
    if (!frame_value(f, v, &array)) return -1;
    JSValue len = JS_GetPropertyStr(f->ctx, array, "length");
    int32_t signed_length = 0;
    int status = JS_ToInt32(f->ctx, &signed_length, len);
    JS_FreeValue(f->ctx, len);
    if (status < 0 || signed_length < 0) return -1;
    *out = (uint32_t)signed_length;
    return 0;
}
static JsValue api_array_get(JsContext *ctx, JsValue v, uint32_t i) { AddonFrame *f = frame_of(ctx); JSValueConst array; if (!frame_value(f, v, &array)) return frame_push(f, JS_ThrowInternalError(f->ctx, "invalid array handle")); return frame_push(f, JS_GetPropertyUint32(f->ctx, array, i)); }
static JsValue api_array(JsContext *ctx) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewArray(f->ctx)); }
static int api_array_set(JsContext *ctx, JsValue v, uint32_t i, JsValue item) { AddonFrame *f = frame_of(ctx); JSValueConst array, value; if (!frame_value(f, v, &array) || !frame_value(f, item, &value)) return -1; return JS_DefinePropertyValueUint32(f->ctx, array, i, JS_DupValue(f->ctx, value), JS_PROP_HAS_VALUE | JS_PROP_HAS_ENUMERABLE | JS_PROP_ENUMERABLE); }
static int api_metric_register(JsContext *ctx, const JsMetricDefinition *d, uint32_t *id) { return hao_metric_register(frame_of(ctx)->ctx, d, id); }
static int api_metric_add(JsContext *ctx, uint32_t id, double value) { return hao_metric_add(frame_of(ctx)->ctx, id, value); }
static int api_metric_set(JsContext *ctx, uint32_t id, double value) { return hao_metric_set(frame_of(ctx)->ctx, id, value); }
static int api_metric_observe(JsContext *ctx, uint32_t id, double value) { return hao_metric_observe(frame_of(ctx)->ctx, id, value); }
static int api_metric_value(JsContext *ctx, uint32_t id, double *value) { return hao_metric_value(frame_of(ctx)->ctx, id, value); }

static const JsContextApi context_api = {
    .abi_version = JS_ADDON_ABI_VERSION, .undefined = api_undefined, .null_value = api_null,
    .bool_value = api_bool, .int32_value = api_int, .float64_value = api_float,
    .string_value = api_string, .to_bool = api_to_bool, .to_int32 = api_to_int,
    .to_float64 = api_to_float, .to_string = api_to_string,
    .throw_type_error = api_type_error, .throw_error = api_error,
    .object_value = api_object, .set_property = api_set, .get_property = api_get,
    .is_undefined = api_is_undefined, .is_null = api_is_null, .is_object = api_is_object,
    .is_array = api_is_array, .is_function = api_is_function, .array_length = api_array_length,
    .array_get = api_array_get, .array_value = api_array, .array_set = api_array_set,
    .metric_register = api_metric_register, .metric_add = api_metric_add,
    .metric_set = api_metric_set, .metric_observe = api_metric_observe,
    .metric_value = api_metric_value,
};

static JSValue call_addon(JSContext *ctx, JSValueConst this_value, int argc,
                          JSValueConst *argv, int magic, JSValue *data) {
    (void)this_value; (void)magic;
    int64_t pointer = 0;
    if (JS_ToInt64(ctx, &pointer, data[0]) < 0) return JS_EXCEPTION;
    const JsFunction *function = (const JsFunction *)(uintptr_t)pointer;
    AddonFrame frame = {.ctx = ctx, .argc = argc, .argv = argv};
    JsContext addon_ctx = {.api = &context_api, .data = &frame};
    JsValue *handles = hao_calloc((size_t)argc ? (size_t)argc : 1, sizeof(*handles));
    if (!handles) return JS_ThrowOutOfMemory(ctx);
    for (int i = 0; i < argc; i++) handles[i] = (size_t)i + 1;
    JsValue returned = function->callback(&addon_ctx, argc, handles);
    hao_free(handles);
    JSValueConst returned_value;
    JSValue result = frame_value(&frame, returned, &returned_value) ?
        JS_DupValue(ctx, returned_value) : JS_EXCEPTION;
    for (size_t i = 0; i < frame.count; i++) JS_FreeValue(ctx, frame.owned[i]);
    for (size_t i = 0; i < frame.string_count; i++) hao_free(frame.strings[i]);
    hao_free(frame.owned); hao_free(frame.strings);
    return result;
}

static int init_module(JSContext *ctx, JSModuleDef *module) {
    JSValue private = JS_GetModulePrivateValue(ctx, module);
    int64_t pointer = 0;
    if (JS_ToInt64(ctx, &pointer, private) < 0) return -1;
    const JsModule *entry = (const JsModule *)(uintptr_t)pointer;
    JSValue exports = JS_NewObject(ctx);
    if (JS_IsException(exports)) return -1;
    for (size_t i = 0; i < entry->function_count; i++) {
        const JsFunction *function = &entry->functions[i];
        JSValue data = JS_NewInt64(ctx, (int64_t)(uintptr_t)function);
        JSValue value = JS_NewCFunctionData(ctx, call_addon, function->length, 0, 1, &data);
        JS_FreeValue(ctx, data);
        if (JS_IsException(value)) { JS_FreeValue(ctx, exports); return -1; }
        if (JS_SetModuleExport(ctx, module, function->name, JS_DupValue(ctx, value)) < 0 ||
            JS_SetPropertyStr(ctx, exports, function->name, value) < 0) {
            JS_FreeValue(ctx, exports); return -1;
        }
    }
    return JS_SetModuleExport(ctx, module, "default", exports);
}

static int add_module(JsRegistry *registry, const JsModule *module) {
    AddonLibrary *library = registry->data;
    if (!module || !module->specifier || !module->functions || module->function_count == 0 || module->function_count > 256) return -1;
    const JsModule **modules = hao_realloc(library->modules, (library->count + 1) * sizeof(*modules));
    if (!modules) return -1;
    library->modules = modules;
    library->modules[library->count++] = module;
    return 0;
}
static const JsRegistryApi registry_api = {.abi_version = JS_ADDON_ABI_VERSION, .add_module = add_module};

static AddonLibrary *load_library(JSContext *ctx, const char *path) {
    for (AddonLibrary *it = libraries; it; it = it->next)
        if (it->ctx == ctx && strcmp(it->path, path) == 0) return it;
    AddonLibrary *library = hao_calloc(1, sizeof(*library));
    if (!library) return NULL;
    library->ctx = ctx;
    library->path = hao_strdup(path);
    library->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    JsRegisterModulesFn register_fn = library->handle ? (JsRegisterModulesFn)dlsym(library->handle, "js_register_modules") : NULL;
    JsRegistry registry = {.api = &registry_api, .data = library};
    if (!library->path || !register_fn || register_fn(&registry) != 0) {
        JS_ThrowReferenceError(ctx, "Cannot load native addon: %s", path);
        if (library->handle) dlclose(library->handle);
        hao_free(library->modules); hao_free(library->path); hao_free(library);
        return NULL;
    }
    library->next = libraries;
    libraries = library;
    return library;
}

JSModuleDef *hao_load_addon(JSContext *ctx, const char *name) {
    const char *newline = strchr(name, '\n');
    if (strncmp(name, "addon:", 6) != 0 || !newline) return NULL;
    char *specifier = hao_strndup(name + 6, (size_t)(newline - name - 6));
    if (!specifier) return NULL;
    AddonLibrary *library = load_library(ctx, newline + 1);
    if (!library) { hao_free(specifier); return NULL; }
    const JsModule *entry = NULL;
    for (size_t i = 0; i < library->count; i++)
        if (strcmp(library->modules[i]->specifier, specifier) == 0) { entry = library->modules[i]; break; }
    if (!entry && library->count == 1) entry = library->modules[0];
    hao_free(specifier);
    if (!entry) { JS_ThrowReferenceError(ctx, "Native addon module not registered: %s", name); return NULL; }
    JSModuleDef *module = JS_NewCModule(ctx, name, init_module);
    if (!module) return NULL;
    JS_SetModulePrivateValue(ctx, module, JS_NewInt64(ctx, (int64_t)(uintptr_t)entry));
    JS_AddModuleExport(ctx, module, "default");
    for (size_t i = 0; i < entry->function_count; i++) JS_AddModuleExport(ctx, module, entry->functions[i].name);
    return module;
}

void hao_addon_cleanup(JSContext *ctx) {
    AddonLibrary **link = &libraries;
    while (*link) {
        AddonLibrary *library = *link;
        if (library->ctx != ctx) { link = &library->next; continue; }
        *link = library->next;
        dlclose(library->handle);
        hao_free(library->modules); hao_free(library->path); hao_free(library);
    }
}

/* JavaScript FFI adapter. */
typedef enum {
    HAO_VOID, HAO_BOOL, HAO_I8, HAO_I16, HAO_I32, HAO_I64,
    HAO_U8, HAO_U16, HAO_U32, HAO_U64, HAO_F32, HAO_F64,
    HAO_PTR, HAO_CSTRING, HAO_BUFFER
} HaoType;

typedef struct HaoBinding {
    char *name;
    void *function;
    size_t arg_count;
    HaoType *args;
    HaoType returns;
    ffi_type *arg_ffi[8];
    ffi_cif cif;
    struct HaoBinding *next;
} HaoBinding;

typedef struct HaoLibrary {
    int64_t id;
    JSContext *ctx;
    void *library;
    bool closed;
    HaoBinding *bindings;
    struct HaoLibrary *next;
} HaoLibrary;

static HaoLibrary *ffi_libraries;
static int64_t ffi_next_id = 1;

static HaoLibrary *find_library(JSContext *ctx, int64_t id) {
    for (HaoLibrary *library = ffi_libraries; library; library = library->next)
        if (library->id == id && library->ctx == ctx) return library;
    return NULL;
}
static HaoBinding *find_binding(HaoLibrary *library, const char *name) {
    for (HaoBinding *binding = library->bindings; binding; binding = binding->next)
        if (strcmp(binding->name, name) == 0) return binding;
    return NULL;
}
static void free_bindings(HaoLibrary *library) {
    HaoBinding *binding = library->bindings;
    library->bindings = NULL;
    while (binding) {
        HaoBinding *next = binding->next;
        hao_free(binding->name);
        hao_free(binding->args);
        hao_free(binding);
        binding = next;
    }
}
static void free_library(HaoLibrary *library) {
    free_bindings(library);
    if (library->library) dlclose(library->library);
    hao_free(library);
}
static void close_library(HaoLibrary *library) {
    if (library->closed) return;
    library->closed = true;
    dlclose(library->library);
    library->library = NULL;
    free_bindings(library);
}
void hao_ffi_cleanup(JSContext *ctx) {
    HaoLibrary **link = &ffi_libraries;
    while (*link) {
        HaoLibrary *library = *link;
        if (library->ctx == ctx) {
            *link = library->next;
            free_library(library);
        } else {
            link = &library->next;
        }
    }
}
static bool parse_type(const char *name, HaoType *out) {
    int code = hao_ffi_type_code((const unsigned char *)name);
    if (code < 0) return false;
    *out = (HaoType)code;
    return true;
}
static ffi_type *ffi_type_for(HaoType type) {
    switch (type) {
        case HAO_VOID: return &ffi_type_void;
        case HAO_BOOL: case HAO_U8: return &ffi_type_uint8;
        case HAO_I8: return &ffi_type_sint8;
        case HAO_I16: return &ffi_type_sint16;
        case HAO_U16: return &ffi_type_uint16;
        case HAO_I32: return &ffi_type_sint32;
        case HAO_U32: return &ffi_type_uint32;
        case HAO_I64: return &ffi_type_sint64;
        case HAO_U64: return &ffi_type_uint64;
        case HAO_F32: return &ffi_type_float;
        case HAO_F64: return &ffi_type_double;
        case HAO_PTR: case HAO_CSTRING: case HAO_BUFFER: return &ffi_type_pointer;
    }
    return NULL;
}
static JSValue open_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsString(argv[0])) return JS_ThrowTypeError(ctx, "dlopen: invalid library name");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_EXCEPTION;
    size_t length = strlen(name);
    if (length > 4096) { JS_FreeCString(ctx, name); return JS_ThrowTypeError(ctx, "dlopen: invalid library name"); }
    char *path = NULL;
    if (!strchr(name, '/') && !strchr(name, '.')) {
        path = hao_alloc(length + 10);
        if (!path) { JS_FreeCString(ctx, name); return JS_ThrowOutOfMemory(ctx); }
#if defined(__APPLE__)
        snprintf(path, length + 10, "lib%s.dylib", name);
#else
        snprintf(path, length + 10, "lib%s.so", name);
#endif
    }
    void *handle = dlopen(path ? path : name, RTLD_NOW | RTLD_LOCAL);
    hao_free(path);
    JS_FreeCString(ctx, name);
    if (!handle) return JS_ThrowInternalError(ctx, "dlopen: failed to open library");
    HaoLibrary *library = hao_calloc(1, sizeof(*library));
    if (!library) { dlclose(handle); return JS_ThrowOutOfMemory(ctx); }
    library->id = ffi_next_id++;
    library->ctx = ctx;
    library->library = handle;
    library->next = ffi_libraries;
    ffi_libraries = library;
    return JS_NewInt64(ctx, library->id);
}
static JSValue bind_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 4 || JS_ToInt64(ctx, &id, argv[0]) != 0 || !JS_IsString(argv[1]) || !JS_IsArray(argv[2]) || !JS_IsString(argv[3]))
        return JS_ThrowTypeError(ctx, "FFI: invalid binding descriptor");
    HaoLibrary *library = find_library(ctx, id);
    if (!library) return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    if (library->closed) return JS_ThrowTypeError(ctx, "FFI: library has been closed");
    const char *name = JS_ToCString(ctx, argv[1]);
    const char *return_name = JS_ToCString(ctx, argv[3]);
    if (!name || !return_name) {
        if (name) JS_FreeCString(ctx, name);
        if (return_name) JS_FreeCString(ctx, return_name);
        return JS_EXCEPTION;
    }
    HaoBinding *binding = hao_calloc(1, sizeof(*binding));
    if (!binding) { JS_FreeCString(ctx, name); JS_FreeCString(ctx, return_name); return JS_ThrowOutOfMemory(ctx); }
    JSValue count_value = JS_GetPropertyStr(ctx, argv[2], "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    bool valid = parse_type(return_name, &binding->returns) && !find_binding(library, name);
    binding->arg_count = count;
    binding->args = hao_calloc(count ? count : 1, sizeof(HaoType));
    valid = valid && binding->args != NULL;
    bool has_void_arg = false;
    for (uint32_t i = 0; valid && i < count; i++) {
        JSValue value = JS_GetPropertyUint32(ctx, argv[2], i);
        const char *type_name = JS_ToCString(ctx, value);
        valid = type_name && parse_type(type_name, &binding->args[i]);
        if (valid && binding->args[i] == HAO_VOID) has_void_arg = true;
        if (valid && i < 8 && !has_void_arg) binding->arg_ffi[i] = ffi_type_for(binding->args[i]);
        if (type_name) JS_FreeCString(ctx, type_name);
        JS_FreeValue(ctx, value);
    }
    if (valid) binding->function = dlsym(library->library, name);
    bool missing_symbol = valid && binding->function == NULL;
    if (missing_symbol) valid = false;
    if (valid && count <= 8 && !has_void_arg) valid = ffi_prep_cif(&binding->cif, FFI_DEFAULT_ABI, count,
        ffi_type_for(binding->returns), binding->arg_ffi) == FFI_OK;
    if (valid) binding->name = hao_strdup(name);
    valid = valid && binding->name;
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, return_name);
    if (!valid) {
        hao_free(binding->args);
        hao_free(binding);
        if (missing_symbol) return JS_ThrowInternalError(ctx, "dlopen: symbol not found");
        return JS_ThrowTypeError(ctx, "dlopen: invalid descriptor");
    }
    binding->next = library->bindings;
    library->bindings = binding;
    return JS_UNDEFINED;
}

typedef union {
    int8_t i8; int16_t i16; int32_t i32; int64_t i64;
    uint8_t u8; uint16_t u16; uint32_t u32; uint64_t u64;
    float f32; double f64; void *ptr;
} HaoValue;

static JSValue result_value(JSContext *ctx, HaoType type, HaoValue value) {
    switch (type) {
        case HAO_VOID: return JS_UNDEFINED;
        case HAO_BOOL: return JS_NewBool(ctx, value.u8 != 0);
        case HAO_I8: return JS_NewInt32(ctx, value.i8);
        case HAO_I16: return JS_NewInt32(ctx, value.i16);
        case HAO_I32: return JS_NewInt32(ctx, value.i32);
        case HAO_I64: return JS_NewInt64(ctx, value.i64);
        case HAO_U8: return JS_NewInt32(ctx, value.u8);
        case HAO_U16: return JS_NewInt32(ctx, value.u16);
        case HAO_U32: return JS_NewInt64(ctx, value.u32);
        case HAO_U64: return JS_NewFloat64(ctx, (double)value.u64);
        case HAO_F32: return JS_NewFloat64(ctx, value.f32);
        case HAO_F64: return JS_NewFloat64(ctx, value.f64);
        case HAO_PTR: case HAO_BUFFER: return JS_NewInt64(ctx, (int64_t)(uintptr_t)value.ptr);
        case HAO_CSTRING: {
            if (!value.ptr) return JS_NULL;
            const char *text = value.ptr;
            return JS_NewStringLen(ctx, text, strlen(text));
        }
    }
    return JS_UNDEFINED;
}

static bool unsigned_arg(JSContext *ctx, JSValueConst input, uint64_t *out) {
    int64_t signed_value = 0;
    if (JS_ToInt64(ctx, &signed_value, input) == 0) {
        if (signed_value < 0) return false;
        *out = (uint64_t)signed_value;
        return true;
    }
    JSValue error = JS_GetException(ctx);
    JS_FreeValue(ctx, error);
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, input);
    if (!text) return false;
    uint64_t parsed = 0;
    bool valid = hao_ffi_parse_unsigned((const unsigned char *)text, length, &parsed) != 0;
    JS_FreeCString(ctx, text);
    if (valid) *out = parsed;
    return valid;
}
static JSValue call_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 3) return JS_ThrowTypeError(ctx, "ffi.callNative requires handle, symbol, and args");
    if (JS_ToInt64(ctx, &id, argv[0]) != 0 || id <= 0) {
        if (JS_HasException(ctx)) {
            JSValue error = JS_GetException(ctx);
            JS_FreeValue(ctx, error);
        }
        return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    }
    HaoLibrary *library = find_library(ctx, id);
    if (!library) return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    if (library->closed) return JS_ThrowTypeError(ctx, "FFI: library has been closed");
    const char *name = JS_ToCString(ctx, argv[1]);
    if (!name) {
        if (JS_HasException(ctx)) {
            JSValue error = JS_GetException(ctx);
            JS_FreeValue(ctx, error);
        }
        return JS_ThrowTypeError(ctx, "FFI: symbol name must be a string");
    }
    HaoBinding *binding = find_binding(library, name);
    JS_FreeCString(ctx, name);
    if (!binding) return JS_ThrowTypeError(ctx, "FFI: unknown symbol");
    if (!JS_IsArray(argv[2])) return JS_ThrowTypeError(ctx, "FFI: arguments must be an array");
    JSValue count_value = JS_GetPropertyStr(ctx, argv[2], "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    if (count != binding->arg_count) return JS_ThrowTypeError(ctx, "FFI: wrong number of arguments");
    int32_t out_index = -1;
    if (argc >= 4 && !JS_IsUndefined(argv[3])) {
        if (JS_ToInt32(ctx, &out_index, argv[3]) < 0 || out_index < 0 || (uint32_t)out_index >= count ||
            binding->args[out_index] != HAO_PTR)
            return JS_ThrowTypeError(ctx, "FFI: invalid output parameter");
    }
    HaoValue stack_values[8] = {0};
    void *stack_pointers[8] = {0};
    JSValue stack_buffers[8];
    const char *stack_strings[8] = {0};
    HaoValue *values = stack_values;
    void **pointers = stack_pointers;
    JSValue *held_buffers = stack_buffers;
    const char **held_strings = stack_strings;
    if (count > 8) {
        values = hao_calloc(count, sizeof(*values));
        pointers = hao_calloc(count, sizeof(*pointers));
        held_buffers = hao_calloc(count, sizeof(*held_buffers));
        held_strings = hao_calloc(count, sizeof(*held_strings));
        if (!values || !pointers || !held_buffers || !held_strings) {
            hao_free(values); hao_free(pointers); hao_free(held_buffers); hao_free(held_strings);
            return JS_ThrowOutOfMemory(ctx);
        }
    }
    uintptr_t out_pointer = 0;
    size_t held_count = 0;
    bool valid = true;
    for (uint32_t i = 0; i < count; i++) {
        JSValue input = JS_GetPropertyUint32(ctx, argv[2], i);
        held_buffers[i] = JS_UNDEFINED;
        pointers[i] = &values[i];
        HaoType type = binding->args[i];
        if (type == HAO_VOID) {
            valid = false;
            JS_ThrowTypeError(ctx, "FFI: void is not a valid argument type");
        } else if ((int32_t)i == out_index) {
            values[i].ptr = &out_pointer;
        } else if (type == HAO_F32 || type == HAO_F64) {
            double number = 0;
            valid = JS_ToFloat64(ctx, &number, input) == 0;
            values[i].f32 = (float)number;
            if (type == HAO_F64) values[i].f64 = number;
        } else if (type == HAO_CSTRING) {
            held_strings[i] = JS_ToCString(ctx, input);
            valid = held_strings[i] != NULL;
            values[i].ptr = (void *)held_strings[i];
        } else if ((type == HAO_PTR || type == HAO_BUFFER) && JS_IsObject(input)) {
            size_t offset = 0, length = 0, total = 0;
            held_buffers[i] = JS_GetTypedArrayBuffer(ctx, input, &offset, &length, NULL);
            if (!JS_IsException(held_buffers[i])) {
                uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, held_buffers[i]);
                valid = bytes && offset <= total && length <= total - offset;
                if (valid) values[i].ptr = bytes + offset;
            } else {
                JSValue error = JS_GetException(ctx);
                JS_FreeValue(ctx, error);
                held_buffers[i] = JS_UNDEFINED;
                uint64_t number = 0;
                valid = unsigned_arg(ctx, input, &number);
                if (valid) values[i].ptr = (void *)(uintptr_t)number;
            }
        } else if (type == HAO_BOOL) {
            int boolean = JS_ToBool(ctx, input);
            valid = boolean >= 0;
            values[i].u8 = boolean > 0;
        } else if (type == HAO_U8 || type == HAO_U16 || type == HAO_U32 || type == HAO_U64 || type == HAO_PTR || type == HAO_BUFFER) {
            uint64_t number = 0;
            valid = unsigned_arg(ctx, input, &number);
            values[i].u64 = number;
            if (type == HAO_U8) values[i].u8 = (uint8_t)number;
            if (type == HAO_U16) values[i].u16 = (uint16_t)number;
            if (type == HAO_U32) values[i].u32 = (uint32_t)number;
            if (type == HAO_PTR || type == HAO_BUFFER) values[i].ptr = (void *)(uintptr_t)number;
        } else {
            int64_t number = 0;
            valid = JS_ToInt64(ctx, &number, input) == 0;
            values[i].i64 = number;
            if (type == HAO_I8) values[i].i8 = (int8_t)number;
            if (type == HAO_I16) values[i].i16 = (int16_t)number;
            if (type == HAO_I32) values[i].i32 = (int32_t)number;
        }
        if (!valid && (type == HAO_PTR || type == HAO_BUFFER)) {
            if (JS_HasException(ctx)) {
                JSValue error = JS_GetException(ctx);
                JS_FreeValue(ctx, error);
            }
            JS_ThrowTypeError(ctx, "FFI: ptr/buffer arguments must be numeric pointer values");
        }
        JS_FreeValue(ctx, input);
        held_count++;
        if (!valid) break;
    }
    JSValue result;
    if (valid && count > 8) {
        result = JS_ThrowInternalError(ctx, "FFI: mixed int/float arguments are not yet supported");
    } else if (valid) {
        HaoValue returned = {0};
        ffi_call(&binding->cif, FFI_FN(binding->function), &returned, pointers);
        result = result_value(ctx, binding->returns, returned);
        if (out_index >= 0 && !JS_IsException(result)) {
            JSValue pair = JS_NewObject(ctx);
            JS_SetPropertyStr(ctx, pair, "raw", result);
            JS_SetPropertyStr(ctx, pair, "out", JS_NewInt64(ctx, (int64_t)out_pointer));
            result = pair;
        }
    } else result = JS_HasException(ctx) ? JS_EXCEPTION :
        JS_ThrowTypeError(ctx, "FFI: invalid argument value");
    for (size_t i = 0; i < held_count; i++) {
        if (held_strings[i]) JS_FreeCString(ctx, held_strings[i]);
        JS_FreeValue(ctx, held_buffers[i]);
    }
    if (count > 8) {
        hao_free(values); hao_free(pointers); hao_free(held_buffers); hao_free(held_strings);
    }
    return result;
}
static JSValue close_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 1) return JS_ThrowTypeError(ctx, "ffi.closeNative requires a handle");
    if (JS_ToInt64(ctx, &id, argv[0]) < 0 || id <= 0)
        return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    HaoLibrary *library = find_library(ctx, id);
    if (library) close_library(library);
    return JS_UNDEFINED;
}
static JSValue is_native_array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return JS_NewBool(ctx, argc > 0 && JS_IsArray(argv[0]));
}
void hao_install_ffi_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_ffi_open", JS_NewCFunction(ctx, open_native, "open", 1));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_bind", JS_NewCFunction(ctx, bind_native, "bind", 4));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_call", JS_NewCFunction(ctx, call_native, "call", 3));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_close", JS_NewCFunction(ctx, close_native, "close", 1));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_isArray", JS_NewCFunction(ctx, is_native_array, "isArray", 1));
}

/* JavaScript filesystem adapter. */
static JSValue hao_fs_arg_error(JSContext *ctx, const char *message) {
    JSValue cause = JS_GetException(ctx);
    JS_FreeValue(ctx, cause);
    return JS_ThrowTypeError(ctx, "%s", message);
}

static JSValue hao_fs_exists_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "existsSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "existsSync expects a path");
    int found = hao_fs_exists((const unsigned char *)path);
    JS_FreeCString(ctx, path);
    return JS_NewBool(ctx, found != 0);
}

static JSValue hao_fs_read_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "readFileSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "readFileSync expects a path");
    unsigned char *buffer = hao_fs_read_alloc((const unsigned char *)path,
                                                      strlen(path), 100 * 1024 * 1024);
    JS_FreeCString(ctx, path);
    if (!buffer) return JS_ThrowInternalError(ctx, "failed to read file");
    JSValue result = JS_NewString(ctx, (const char *)buffer);
    hao_free(buffer);
    return result;
}

static JSValue hao_fs_write_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "writeFileSync expects a path");
    if (argc < 2) return JS_ThrowTypeError(ctx, "writeFileSync expects data");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "writeFileSync expects a path");
    size_t length = 0;
    const char *data = JS_ToCStringLen(ctx, &length, argv[1]);
    if (!data) {
        JS_FreeCString(ctx, path);
        return hao_fs_arg_error(ctx, "writeFileSync expects data");
    }
    int status = hao_fs_write((const unsigned char *)path, (const unsigned char *)data, strlen(data));
    JS_FreeCString(ctx, data);
    JS_FreeCString(ctx, path);
    if (status != 0) return JS_ThrowInternalError(ctx, "failed to write file");
    return JS_UNDEFINED;
}

static JSValue hao_fs_stat_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "statSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "statSync expects a path");
    FILE *file = fopen(path, "rb");
    JS_FreeCString(ctx, path);
    if (!file) return JS_ThrowInternalError(ctx, "failed to stat file");
    int status = fseek(file, 0, SEEK_END);
    long size = status == 0 ? ftell(file) : -1;
    fclose(file);
    if (size < 0) return JS_ThrowInternalError(ctx, "failed to stat file");
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    JS_SetPropertyStr(ctx, result, "size", JS_NewFloat64(ctx, (double)size));
    return result;
}

void hao_install_fs_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_fs_existsSync", JS_NewCFunction(ctx, hao_fs_exists_sync, "existsSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_readFileSync", JS_NewCFunction(ctx, hao_fs_read_file_sync, "readFileSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_writeFileSync", JS_NewCFunction(ctx, hao_fs_write_file_sync, "writeFileSync", 2));
    JS_SetPropertyStr(ctx, global, "__hao_fs_statSync", JS_NewCFunction(ctx, hao_fs_stat_sync, "statSync", 1));
}

/* HTTP client adapter. */
typedef struct HaoHeader {
    char *name;
    char *value;
    struct HaoHeader *next;
} HaoHeader;

typedef struct {
    unsigned char *body;
    size_t length, capacity, limit;
    HaoHeader *headers;
    HaoHeader *headers_tail;
    char status_text[128];
    int failed;
    int skip_body;
    bool chunked;
    bool manual_redirect;
    bool has_request_body;
    bool post_request;
    bool redirect_requires_resend;
    bool redirect_to_get;
    bool custom_method;
    long redirect_status;
    char *redirect_location;
    FILE *download_file;
    EVP_MD_CTX *digest;
} HaoHttpResponse;

typedef struct {
    uv_work_t work;
    JSContext *ctx;
    JSValue resolve;
    JSValue reject;
    JSValue trace_context;
    char *url;
    char *method;
    char *download_path;
    char *body;
    size_t body_length;
    bool has_body;
    bool manual_redirect;
    struct curl_slist *request_headers;
    HaoHttpResponse response;
    char *final_url;
    long status;
    char sha256[65];
    char error[256];
    bool legacy_error;
} HaoHttpJob;

static void free_headers(HaoHeader *header) {
    while (header) {
        HaoHeader *next = header->next;
        hao_free(header->name);
        hao_free(header->value);
        hao_free(header);
        header = next;
    }
}
static void destroy_job(HaoHttpJob *job) {
    hao_free(job->url);
    hao_free(job->method);
    hao_free(job->download_path);
    hao_free(job->body);
    hao_free(job->final_url);
    hao_free(job->response.redirect_location);
    hao_free(job->response.body);
    free_headers(job->response.headers);
    curl_slist_free_all(job->request_headers);
    JS_FreeValue(job->ctx, job->resolve);
    JS_FreeValue(job->ctx, job->reject);
    JS_FreeValue(job->ctx, job->trace_context);
    hao_free(job);
}
static JSValue telemetry_enter_context(JSContext *ctx, JSValueConst context) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue enter = JS_GetPropertyStr(ctx, global, "__hao_telemetry_enterContext");
    JSValue previous = JS_UNDEFINED;
    if (JS_IsFunction(ctx, enter)) previous = JS_Call(ctx, enter, global, 1, &context);
    JS_FreeValue(ctx, enter);
    JS_FreeValue(ctx, global);
    return previous;
}
static void retain_callback_error(HaoRuntime *host, JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    if (!host->has_callback_error) {
        host->callback_error = error;
        host->has_callback_error = true;
    } else {
        JS_FreeValue(ctx, error);
    }
}
static size_t receive_body(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (response->skip_body) return length;
    if (length > response->limit - response->length) { response->failed = 1; return 0; }
    if (response->download_file) {
        if (length && fwrite(data, 1, length, response->download_file) != length) { response->failed = 3; return 0; }
        if (EVP_DigestUpdate(response->digest, data, length) != 1) { response->failed = 3; return 0; }
        response->length += length;
        return length;
    }
    if (response->length + length > response->capacity) {
        size_t capacity = response->capacity ? response->capacity : 4096;
        while (capacity < response->length + length) {
            if (capacity > response->limit / 2) { capacity = response->limit; break; }
            capacity *= 2;
        }
        unsigned char *next = hao_realloc(response->body, capacity);
        if (!next) { response->failed = 2; return 0; }
        response->body = next;
        response->capacity = capacity;
    }
    memcpy(response->body + response->length, data, length);
    response->length += length;
    return length;
}
static size_t receive_header(char *data, size_t size, size_t count, void *opaque) {
    HaoHttpResponse *response = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length >= 5 && memcmp(data, "HTTP/", 5) == 0) {
        response->skip_body = 0;
        response->chunked = false;
        response->redirect_status = 0;
        char *space = memchr(data, ' ', length);
        if (space) {
            long status = strtol(space + 1, NULL, 10);
            response->redirect_status = status;
            response->skip_body = (status >= 100 && status < 200) ||
                (!response->manual_redirect && status >= 300 && status < 400);
        }
        free_headers(response->headers);
        response->headers = NULL;
        response->headers_tail = NULL;
        response->status_text[0] = 0;
        if (space) {
            char *reason = memchr(space + 1, ' ', (size_t)(data + length - space - 1));
            if (reason) {
                size_t n = (size_t)(data + length - reason - 1);
                while (n && (reason[n] == '\r' || reason[n] == '\n')) n--;
                if (n >= sizeof(response->status_text)) n = sizeof(response->status_text) - 1;
                memcpy(response->status_text, reason + 1, n);
                response->status_text[n] = 0;
            }
        }
        return length;
    }
    char *colon = memchr(data, ':', length);
    if (!colon || colon == data) return length;
    size_t name_length = (size_t)(colon - data);
    if (!response->manual_redirect && response->has_request_body &&
        ((response->redirect_status == 307 || response->redirect_status == 308) ||
         (!response->post_request && response->redirect_status >= 301 &&
          response->redirect_status <= 302)) &&
        name_length == 8 && strncasecmp(data, "Location", 8) == 0) {
        response->redirect_requires_resend = true;
        return 0;
    }
    const char *value = colon + 1;
    size_t value_length = (size_t)(data + length - value);
    while (value_length && isspace((unsigned char)*value)) { value++; value_length--; }
    while (value_length && isspace((unsigned char)value[value_length - 1])) value_length--;
    if (!response->manual_redirect && response->custom_method &&
        response->redirect_status == 303 && name_length == 8 &&
        strncasecmp(data, "Location", 8) == 0 && value_length) {
        response->redirect_location = hao_alloc(value_length + 1);
        if (!response->redirect_location) { response->failed = 2; return 0; }
        memcpy(response->redirect_location, value, value_length);
        response->redirect_location[value_length] = 0;
        response->redirect_to_get = true;
        return 0;
    }
    if (name_length == 17 && strncasecmp(data, "Transfer-Encoding", 17) == 0) {
        const char *token = value;
        size_t remaining = value_length;
        while (remaining) {
            while (remaining && (*token == ',' || isspace((unsigned char)*token))) {
                token++; remaining--;
            }
            size_t token_length = 0;
            while (token_length < remaining && token[token_length] != ',') token_length++;
            size_t trimmed = token_length;
            while (trimmed && isspace((unsigned char)token[trimmed - 1])) trimmed--;
            if (trimmed == 7 && strncasecmp(token, "chunked", 7) == 0) response->chunked = true;
            token += token_length;
            remaining -= token_length;
        }
    }
    HaoHeader *header = hao_calloc(1, sizeof(*header));
    if (!header) { response->failed = 2; return 0; }
    header->name = hao_alloc(name_length + 1);
    header->value = hao_alloc(value_length + 1);
    if (!header->name || !header->value) {
        free_headers(header);
        response->failed = 2;
        return 0;
    }
    memcpy(header->name, data, name_length); header->name[name_length] = 0;
    memcpy(header->value, value, value_length); header->value[value_length] = 0;
    if (response->headers_tail) response->headers_tail->next = header;
    else response->headers = header;
    response->headers_tail = header;
    return length;
}
static void set_error(HaoHttpJob *job, const char *message) {
    snprintf(job->error, sizeof(job->error), "%s", message);
}
static void set_legacy_error(HaoHttpJob *job, const char *name) {
    snprintf(job->error, sizeof(job->error), "http.request error: %s", name);
    job->legacy_error = true;
}
static bool same_origin(CURLU *first, CURLU *second) {
    const CURLUPart parts[] = { CURLUPART_SCHEME, CURLUPART_HOST, CURLUPART_PORT };
    bool same = true;
    for (size_t i = 0; i < 3; i++) {
        char *left = NULL, *right = NULL;
        CURLUcode a = curl_url_get(first, parts[i], &left, CURLU_DEFAULT_PORT);
        CURLUcode b = curl_url_get(second, parts[i], &right, CURLU_DEFAULT_PORT);
        if (a != CURLUE_OK || b != CURLUE_OK || strcasecmp(left, right) != 0) same = false;
        curl_free(left); curl_free(right);
        if (!same) break;
    }
    return same;
}
static bool sensitive_header(const char *header) {
    return strncasecmp(header, "Authorization:", 14) == 0 ||
        strncasecmp(header, "Cookie:", 7) == 0;
}
static void perform_http(uv_work_t *work) {
    HaoHttpJob *job = work->data;
    HaoHttpResponse *response = &job->response;
    bool follow_redirect = !job->manual_redirect && strcmp(job->method, "HEAD") != 0;
    response->manual_redirect = !follow_redirect;
    response->has_request_body = job->has_body;
    response->post_request = strcmp(job->method, "POST") == 0;
    response->custom_method = strcmp(job->method, "GET") != 0 &&
        strcmp(job->method, "POST") != 0;
    CURL *curl = NULL;
    struct curl_slist *redirect_headers = NULL;
    char *temporary_path = NULL;
    unsigned char *transport_url = NULL;
    static const char *const url_errors[] = {NULL, "InvalidFormat", "UnexpectedCharacter",
        "UnsupportedUriScheme", "UriMissingHost", "InvalidPort", "InvalidHostName"};
    int url_error = hao_http_url_error((const unsigned char *)job->url);
    if (url_error > 0 && (size_t)url_error < sizeof(url_errors) / sizeof(url_errors[0])) {
        set_legacy_error(job, url_errors[url_error]);
        goto done;
    }
    transport_url = hao_http_transport_url((const unsigned char *)job->url);
    if (!transport_url) { set_error(job, "out of memory"); goto done; }
    if (job->download_path) {
        size_t length = strlen(job->download_path);
        temporary_path = hao_alloc(length + 17);
        if (!temporary_path) { set_error(job, "out of memory"); goto done; }
        snprintf(temporary_path, length + 17, "%s.hao-XXXXXX", job->download_path);
        int fd = mkstemp(temporary_path);
        if (fd < 0) { set_error(job, "unable to create download file"); goto done; }
        response->download_file = fdopen(fd, "wb");
        if (!response->download_file) { close(fd); set_error(job, "unable to open download file"); goto done; }
        response->digest = EVP_MD_CTX_new();
        if (!response->digest || EVP_DigestInit_ex(response->digest, EVP_sha256(), NULL) != 1) {
            set_error(job, "unable to initialize download digest"); goto done;
        }
    }
    curl = curl_easy_init();
    if (!curl) { set_error(job, "unable to initialize HTTP client"); goto done; }
    curl_easy_setopt(curl, CURLOPT_URL, (const char *)transport_url);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    if (strcmp(job->method, "POST") == 0) curl_easy_setopt(curl, CURLOPT_POST, 1L);
    else if (strcmp(job->method, "GET") != 0 || job->has_body)
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, job->method);
    if (strcmp(job->method, "HEAD") == 0) curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, follow_redirect ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive_body);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, receive_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, response);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 30000L);
    if (job->has_body) {
        bool has_content_type = false;
        for (struct curl_slist *header = job->request_headers; header; header = header->next) {
            if (strncasecmp(header->data, "Content-Type:", 13) == 0) {
                has_content_type = true;
                break;
            }
        }
        if (!has_content_type) {
            struct curl_slist *headers = curl_slist_append(job->request_headers, "Content-Type:");
            if (!headers) { set_error(job, "out of memory"); goto done; }
            job->request_headers = headers;
        }
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, job->body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)job->body_length);
    } else if (strcmp(job->method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
    }
    if (job->request_headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, job->request_headers);
    CURLcode code = curl_easy_perform(curl);
    if (response->redirect_to_get) {
        char *current_url = NULL;
        long followed = 0;
        curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &current_url);
        curl_easy_getinfo(curl, CURLINFO_REDIRECT_COUNT, &followed);
        CURLU *url = curl_url();
        CURLU *origin = NULL;
        char *next_url = NULL;
        CURLUcode url_status = url && current_url ? curl_url_set(url, CURLUPART_URL, current_url, 0) : CURLUE_BAD_HANDLE;
        if (url_status == CURLUE_OK) origin = curl_url_dup(url);
        if (url_status == CURLUE_OK && !origin) { curl_url_cleanup(url); set_error(job, "out of memory"); goto done; }
        if (url_status == CURLUE_OK)
            url_status = curl_url_set(url, CURLUPART_URL, response->redirect_location, 0);
        if (url_status == CURLUE_OK) url_status = curl_url_get(url, CURLUPART_URL, &next_url, 0);
        if (url_status != CURLUE_OK || followed >= 3) {
            if (next_url) curl_free(next_url);
            if (origin) curl_url_cleanup(origin);
            if (url) curl_url_cleanup(url);
            set_legacy_error(job, followed >= 3 ? "TooManyHttpRedirects" : "InvalidFormat");
            goto done;
        }
        if (!same_origin(origin, url)) {
            for (struct curl_slist *header = job->request_headers; header; header = header->next) {
                if (sensitive_header(header->data)) continue;
                struct curl_slist *next = curl_slist_append(redirect_headers, header->data);
                if (!next) {
                    curl_url_cleanup(origin); curl_url_cleanup(url); curl_free(next_url);
                    set_error(job, "out of memory"); goto done;
                }
                redirect_headers = next;
            }
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, redirect_headers);
        }
        curl_url_cleanup(origin);
        curl_easy_setopt(curl, CURLOPT_URL, next_url);
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, NULL);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, NULL);
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 2L - followed);
        response->custom_method = false;
        response->has_request_body = false;
        response->redirect_to_get = false;
        response->redirect_status = 0;
        response->skip_body = 0;
        response->chunked = false;
        response->status_text[0] = 0;
        free_headers(response->headers);
        response->headers = response->headers_tail = NULL;
        curl_free(next_url);
        curl_url_cleanup(url);
        code = curl_easy_perform(curl);
    }
    if (code != CURLE_OK) {
        if (response->redirect_requires_resend) {
            set_legacy_error(job, "RedirectRequiresResend");
            goto done;
        }
        if (response->failed == 1) {
            set_legacy_error(job, job->download_path ? "DownloadTooLarge" : "ResponseTooLarge");
            goto done;
        }
        if (code == CURLE_PARTIAL_FILE) {
            if (response->chunked || job->download_path) {
                set_legacy_error(job, response->chunked ? "HttpChunkTruncated" : "TruncatedDownload");
                goto done;
            }
        } else {
            const char *legacy_name = NULL;
            if (code == CURLE_COULDNT_CONNECT) legacy_name = "ConnectionRefused";
            if (code == CURLE_COULDNT_RESOLVE_HOST) legacy_name = "UnknownHostName";
            if (code == CURLE_URL_MALFORMAT) legacy_name = "InvalidFormat";
            if (code == CURLE_UNSUPPORTED_PROTOCOL) legacy_name = "UnsupportedUriScheme";
            if (code == CURLE_TOO_MANY_REDIRECTS) legacy_name = "TooManyHttpRedirects";
            if (legacy_name) set_legacy_error(job, legacy_name);
            else set_error(job, curl_easy_strerror(code));
            goto done;
        }
    }
    char *effective_url = NULL;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &job->status);
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
    job->final_url = hao_strdup(effective_url ? effective_url : job->url);
    if (!job->final_url) { set_error(job, "out of memory"); goto done; }
    if (job->download_path) {
        if (job->status < 200 || job->status >= 300) { set_error(job, "http.download requires a successful response"); goto done; }
        if (fflush(response->download_file) != 0 || fsync(fileno(response->download_file)) != 0) {
            set_error(job, "unable to finish download file"); goto done;
        }
        if (fclose(response->download_file) != 0) {
            response->download_file = NULL;
            set_error(job, "unable to close download file"); goto done;
        }
        response->download_file = NULL;
        unsigned char digest[32]; unsigned int digest_length = 0;
        const char digits[] = "0123456789abcdef";
        if (EVP_DigestFinal_ex(response->digest, digest, &digest_length) != 1 || digest_length != 32) {
            set_error(job, "unable to finish download digest"); goto done;
        }
        if (rename(temporary_path, job->download_path) != 0) {
            set_error(job, "unable to replace download destination"); goto done;
        }
        for (size_t i = 0; i < 32; i++) {
            job->sha256[i * 2] = digits[digest[i] >> 4];
            job->sha256[i * 2 + 1] = digits[digest[i] & 15];
        }
        job->sha256[64] = 0;
    }
 done:
    EVP_MD_CTX_free(response->digest);
    response->digest = NULL;
    if (response->download_file) fclose(response->download_file);
    if (temporary_path) { unlink(temporary_path); hao_free(temporary_path); }
    if (curl) curl_easy_cleanup(curl);
    curl_slist_free_all(redirect_headers);
    hao_free(transport_url);
}
static int append_response_header(JSContext *ctx, JSValueConst headers, const HaoHeader *header) {
    JSValue existing = JS_GetPropertyStr(ctx, headers, header->name);
    if (JS_IsException(existing)) return -1;
    if (JS_IsUndefined(existing)) {
        JS_FreeValue(ctx, existing);
        return JS_SetPropertyStr(ctx, headers, header->name, JS_NewString(ctx, header->value));
    }
    if (JS_IsArray(existing)) {
        JSValue length_value = JS_GetPropertyStr(ctx, existing, "length");
        int32_t length = 0;
        int status = JS_ToInt32(ctx, &length, length_value);
        JS_FreeValue(ctx, length_value);
        if (status < 0 || length < 0) { JS_FreeValue(ctx, existing); return -1; }
        status = JS_SetPropertyUint32(ctx, existing, (uint32_t)length, JS_NewString(ctx, header->value));
        JS_FreeValue(ctx, existing);
        return status;
    }
    JSValue values = JS_NewArray(ctx);
    if (JS_IsException(values)) { JS_FreeValue(ctx, existing); return -1; }
    int status = JS_SetPropertyUint32(ctx, values, 0, JS_DupValue(ctx, existing));
    JS_FreeValue(ctx, existing);
    if (status >= 0) status = JS_SetPropertyUint32(ctx, values, 1, JS_NewString(ctx, header->value));
    if (status >= 0) status = JS_SetPropertyStr(ctx, headers, header->name, values);
    else JS_FreeValue(ctx, values);
    return status;
}
static JSValue make_response(HaoHttpJob *job) {
    JSContext *ctx = job->ctx;
    HaoHttpResponse *response = &job->response;
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    JSValue headers = JS_NewObject(ctx);
    if (JS_IsException(headers)) { JS_FreeValue(ctx, result); return headers; }
    for (HaoHeader *header = response->headers; header; header = header->next) {
        if (append_response_header(ctx, headers, header) < 0) {
            JS_FreeValue(ctx, headers);
            JS_FreeValue(ctx, result);
            return JS_EXCEPTION;
        }
    }
    JS_SetPropertyStr(ctx, result, "status", JS_NewInt32(ctx, (int)job->status));
    JS_SetPropertyStr(ctx, result, "statusText", JS_NewString(ctx, response->status_text));
    JS_SetPropertyStr(ctx, result, "url", JS_NewString(ctx, job->final_url));
    JS_SetPropertyStr(ctx, result, "headers", headers);
    if (job->download_path) {
        JS_SetPropertyStr(ctx, result, "ok", JS_TRUE);
        JS_SetPropertyStr(ctx, result, "bytesWritten", JS_NewFloat64(ctx, (double)response->length));
        JS_SetPropertyStr(ctx, result, "sha256", JS_NewString(ctx, job->sha256));
    } else {
        JS_SetPropertyStr(ctx, result, "bodyText", JS_NewStringLen(ctx, (const char *)response->body, response->length));
        JSValue array_buffer = JS_NewArrayBufferCopy(ctx, response->body, response->length);
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue constructor = JS_GetPropertyStr(ctx, global, "Uint8Array");
        JSValue bytes = JS_CallConstructor(ctx, constructor, 1, &array_buffer);
        JS_SetPropertyStr(ctx, result, "bodyBytes", bytes);
        JS_FreeValue(ctx, constructor);
        JS_FreeValue(ctx, global);
        JS_FreeValue(ctx, array_buffer);
    }
    return result;
}
static void finish_http(uv_work_t *work, int status) {
    HaoHttpJob *job = work->data;
    JSContext *ctx = job->ctx;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    if (status < 0 && !job->error[0]) set_error(job, uv_strerror(status));
    JSValue value;
    JSValue callback;
    if (job->error[0]) {
        if (job->legacy_error) {
            JS_ThrowInternalError(ctx, "%s", job->error);
            value = JS_GetException(ctx);
        } else {
            value = JS_NewError(ctx);
            JS_SetPropertyStr(ctx, value, "message", JS_NewString(ctx, job->error));
        }
        callback = job->reject;
    } else {
        value = make_response(job);
        if (JS_IsException(value)) {
            value = JS_GetException(ctx);
            callback = job->reject;
        } else callback = job->resolve;
    }
    JSValue previous = JS_UNDEFINED;
    if (!JS_IsUndefined(job->trace_context)) {
        previous = telemetry_enter_context(ctx, job->trace_context);
        if (JS_IsException(previous)) retain_callback_error(host, ctx);
    }
    JSValue result = JS_Call(ctx, callback, JS_UNDEFINED, 1, &value);
    if (JS_IsException(result)) retain_callback_error(host, ctx);
    if (!JS_IsUndefined(previous) && !JS_IsException(previous)) {
        JSValue restored = telemetry_enter_context(ctx, previous);
        if (JS_IsException(restored)) retain_callback_error(host, ctx);
        JS_FreeValue(ctx, restored);
    }
    JS_FreeValue(ctx, previous);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, value);
    destroy_job(job);
}
static char *copy_property(JSContext *ctx, JSValueConst object, const char *name) {
    JSValue value = JS_GetPropertyStr(ctx, object, name);
    const char *text = JS_IsNull(value) || JS_IsUndefined(value) ? NULL : JS_ToCString(ctx, value);
    char *copy = text ? hao_strdup(text) : NULL;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, value);
    return copy;
}
static bool parse_options(HaoHttpJob *job, JSValueConst options) {
    JSContext *ctx = job->ctx;
    job->url = copy_property(ctx, options, "url");
    job->method = copy_property(ctx, options, "method");
    char *redirect = copy_property(ctx, options, "redirect");
    if (redirect) { job->manual_redirect = strcmp(redirect, "manual") == 0; hao_free(redirect); }
    JSValue limit = JS_GetPropertyStr(ctx, options, "maxBytes");
    double max_bytes = 1024.0 * 1024.0 * 1024.0;
    if (!JS_IsUndefined(limit) &&
        (JS_ToFloat64(ctx, &max_bytes, limit) < 0 || !isfinite(max_bytes) ||
         max_bytes < 1 || max_bytes > 9007199254740991.0 || floor(max_bytes) != max_bytes ||
         max_bytes >= (double)SIZE_MAX)) {
        JS_FreeValue(ctx, limit);
        return false;
    }
    JS_FreeValue(ctx, limit);
    if (!job->url || !job->method || !hao_http_valid_method((const unsigned char *)job->method)) return false;
    job->response.limit = (size_t)max_bytes;
    JSValue path = JS_GetPropertyStr(ctx, options, "downloadPath");
    if (!JS_IsUndefined(path) && !JS_IsNull(path)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, path);
        if (text && length && !memchr(text, 0, length)) job->download_path = hao_strdup(text);
        if (text) JS_FreeCString(ctx, text);
        if (!job->download_path) { JS_FreeValue(ctx, path); return false; }
    }
    JS_FreeValue(ctx, path);
    JSValue body = JS_GetPropertyStr(ctx, options, "body");
    if (JS_IsString(body)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, body);
        if (!text) { JS_FreeValue(ctx, body); return false; }
        job->body = hao_alloc(length ? length : 1);
        if (job->body) memcpy(job->body, text, length);
        job->body_length = length;
        job->has_body = true;
        JS_FreeCString(ctx, text);
    } else if (JS_IsObject(body)) {
        size_t offset = 0, length = 0, total = 0;
        JSValue buffer = JS_GetTypedArrayBuffer(ctx, body, &offset, &length, NULL);
        if (JS_IsException(buffer)) { JS_FreeValue(ctx, body); return false; }
        uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
        if (!bytes || offset > total || length > total - offset) { JS_FreeValue(ctx, buffer); JS_FreeValue(ctx, body); return false; }
        job->body = hao_alloc(length ? length : 1);
        if (job->body) memcpy(job->body, bytes + offset, length);
        job->body_length = length;
        job->has_body = true;
        JS_FreeValue(ctx, buffer);
    } else if (!JS_IsUndefined(body) && !JS_IsNull(body)) { JS_FreeValue(ctx, body); return false; }
    JS_FreeValue(ctx, body);
    if (job->has_body && !job->body) return false;
    if (job->download_path && (strcmp(job->method, "GET") != 0 || job->has_body)) return false;
    JSValue headers = JS_GetPropertyStr(ctx, options, "headers");
    if (JS_IsUndefined(headers) || JS_IsNull(headers)) { JS_FreeValue(ctx, headers); return true; }
    if (!JS_IsObject(headers)) { JS_FreeValue(ctx, headers); return false; }
    JSValue count_value = JS_GetPropertyStr(ctx, headers, "length");
    int32_t count = 0;
    int count_status = JS_ToInt32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    if (count_status < 0 || count < 0) { JS_FreeValue(ctx, headers); return false; }
    for (int32_t i = 0; i < count; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, headers, i);
        if (!JS_IsObject(pair)) { JS_FreeValue(ctx, pair); JS_FreeValue(ctx, headers); return false; }
        JSValue name_value = JS_GetPropertyUint32(ctx, pair, 0);
        JSValue value_value = JS_GetPropertyUint32(ctx, pair, 1);
        const char *name = JS_ToCString(ctx, name_value);
        const char *value = JS_ToCString(ctx, value_value);
        if (!name || !value || strchr(name, '\r') || strchr(name, '\n') || strchr(value, '\r') || strchr(value, '\n')) {
            if (name) JS_FreeCString(ctx, name);
            if (value) JS_FreeCString(ctx, value);
            JS_FreeValue(ctx, name_value); JS_FreeValue(ctx, value_value); JS_FreeValue(ctx, pair); JS_FreeValue(ctx, headers);
            return false;
        }
        size_t length = strlen(name) + strlen(value) + 3;
        char *line = hao_alloc(length);
        bool appended = false;
        if (line) {
            snprintf(line, length, "%s: %s", name, value);
            struct curl_slist *next = curl_slist_append(job->request_headers, line);
            if (next) { job->request_headers = next; appended = true; }
            hao_free(line);
        }
        JS_FreeCString(ctx, name); JS_FreeCString(ctx, value);
        JS_FreeValue(ctx, name_value); JS_FreeValue(ctx, value_value); JS_FreeValue(ctx, pair);
        if (!appended) { JS_FreeValue(ctx, headers); return false; }
    }
    JS_FreeValue(ctx, headers);
    return true;
}
static JSValue request_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) return JS_ThrowTypeError(ctx, "http request options required");
    HaoHttpJob *job = hao_calloc(1, sizeof(*job));
    if (!job) return JS_ThrowOutOfMemory(ctx);
    job->ctx = ctx;
    job->resolve = JS_UNDEFINED;
    job->reject = JS_UNDEFINED;
    job->trace_context = JS_UNDEFINED;
    if (!parse_options(job, argv[0])) {
        destroy_job(job);
        return JS_ThrowTypeError(ctx, "http.request options are invalid");
    }
    JSValue functions[2];
    JSValue promise = JS_NewPromiseCapability(ctx, functions);
    if (JS_IsException(promise)) { destroy_job(job); return promise; }
    job->resolve = functions[0];
    job->reject = functions[1];
    job->trace_context = JS_GetPropertyStr(ctx, argv[0], "__haoTraceContext");
    if (JS_IsException(job->trace_context)) {
        JS_FreeValue(ctx, promise);
        destroy_job(job);
        return JS_EXCEPTION;
    }
    job->work.data = job;
    uv_loop_t *loop = hao_runtime_loop(ctx);
    int status = loop ? uv_queue_work(loop, &job->work, perform_http, finish_http) : UV_EINVAL;
    if (status != 0) {
        JS_FreeValue(ctx, promise);
        destroy_job(job);
        return JS_ThrowInternalError(ctx, "unable to queue HTTP request");
    }
    return promise;
}
void hao_install_http_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_http_requestNative", JS_NewCFunction(ctx, request_native, "requestNative", 1));
}

/* libuv HTTP server adapter. */
typedef struct HaoServer HaoServer;
typedef struct HaoClient HaoClient;
typedef struct HaoWrite HaoWrite;

struct HaoServer {
    uv_tcp_t listener;
    JSContext *ctx;
    JSValue callback;
    int64_t id;
    unsigned max_connections;
    unsigned connections;
    uint64_t timeout_ms;
    int references;
    bool closing;
    HaoClient *clients;
    HaoServer *next;
};
struct HaoClient {
    uv_tcp_t tcp;
    uv_timer_t timer;
    HaoServer *server;
    int64_t id;
    int handles;
    bool closing;
    bool responding;
    HaoClient *next;
};
struct HaoWrite {
    uv_write_t request;
    HaoClient *client;
    char *bytes;
};

static HaoServer *servers;
static int64_t next_id = 1;

static HaoServer *find_server(int64_t id) {
    for (HaoServer *server = servers; server; server = server->next)
        if (server->id == id) return server;
    return NULL;
}
static HaoClient *find_client(int64_t id) {
    for (HaoServer *server = servers; server; server = server->next)
        for (HaoClient *client = server->clients; client; client = client->next)
            if (client->id == id) return client;
    return NULL;
}
static void unlink_server(HaoServer *server) {
    HaoServer **link = &servers;
    while (*link && *link != server) link = &(*link)->next;
    if (*link) *link = server->next;
}
static void release_server(HaoServer *server) {
    if (--server->references != 0) return;
    JS_FreeValue(server->ctx, server->callback);
    hao_free(server);
}
static bool notify_client(HaoClient *client, JSValue value) {
    HaoServer *server = client->server;
    JSValue id = JS_NewInt64(server->ctx, client->id);
    JSValue args[] = { id, value };
    JSValue result = JS_Call(server->ctx, server->callback, JS_UNDEFINED, 2, args);
    JS_FreeValue(server->ctx, id);
    JS_FreeValue(server->ctx, value);
    if (JS_IsException(result)) {
        JSValue error = JS_GetException(server->ctx);
        JS_FreeValue(server->ctx, error);
        return false;
    }
    JS_FreeValue(server->ctx, result);
    return true;
}
static void client_closed(uv_handle_t *handle) {
    HaoClient *client = handle->data;
    if (--client->handles != 0) return;
    HaoServer *server = client->server;
    hao_free(client);
    release_server(server);
}
static void close_client(HaoClient *client) {
    if (client->closing) return;
    client->closing = true;
    HaoServer *server = client->server;
    HaoClient **link = &server->clients;
    while (*link && *link != client) link = &(*link)->next;
    if (*link) *link = client->next;
    server->connections--;
    uv_read_stop((uv_stream_t *)&client->tcp);
    if (client->handles == 2) {
        uv_timer_stop(&client->timer);
        uv_close((uv_handle_t *)&client->timer, client_closed);
    }
    uv_close((uv_handle_t *)&client->tcp, client_closed);
    if (!server->closing) (void)notify_client(client, JS_NULL);
}
static void listener_closed(uv_handle_t *handle) {
    HaoServer *server = handle->data;
    release_server(server);
}
static void stop_server(HaoServer *server) {
    if (server->closing) return;
    server->closing = true;
    unlink_server(server);
    while (server->clients) close_client(server->clients);
    uv_close((uv_handle_t *)&server->listener, listener_closed);
}
void hao_http_server_cleanup(JSContext *ctx) {
    HaoServer *server = servers;
    while (server) {
        HaoServer *next = server->next;
        if (server->ctx == ctx) stop_server(server);
        server = next;
    }
}
static void client_timeout(uv_timer_t *timer) { close_client(timer->data); }
static void allocate_buffer(uv_handle_t *handle, size_t suggested, uv_buf_t *buf) {
    (void)handle; (void)suggested;
    buf->base = hao_alloc(65536);
    buf->len = buf->base ? 65536 : 0;
}
static JSValue bytes_value(JSContext *ctx, const char *bytes, size_t length) {
    JSValue array_buffer = JS_NewArrayBufferCopy(ctx, (const uint8_t *)bytes, length);
    if (JS_IsException(array_buffer)) return array_buffer;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue constructor = JS_GetPropertyStr(ctx, global, "Uint8Array");
    JSValue value = JS_CallConstructor(ctx, constructor, 1, &array_buffer);
    JS_FreeValue(ctx, constructor);
    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, array_buffer);
    return value;
}
static void read_client(uv_stream_t *stream, ssize_t count, const uv_buf_t *buf) {
    HaoClient *client = stream->data;
    if (count < 0) {
        hao_free(buf->base);
        close_client(client);
        return;
    }
    if (count == 0) { hao_free(buf->base); return; }
    JSValue value = bytes_value(client->server->ctx, buf->base, (size_t)count);
    hao_free(buf->base);
    if (JS_IsException(value)) {
        JSValue error = JS_GetException(client->server->ctx);
        JS_FreeValue(client->server->ctx, error);
        close_client(client);
        return;
    }
    if (!notify_client(client, value)) close_client(client);
}
static void accept_client(uv_stream_t *stream, int status) {
    if (status < 0) return;
    HaoServer *server = stream->data;
    HaoClient *client = hao_calloc(1, sizeof(*client));
    if (!client) return;
    client->server = server;
    client->id = next_id++;
    if (uv_tcp_init(uv_handle_get_loop((uv_handle_t *)stream), &client->tcp) != 0) { hao_free(client); return; }
    client->tcp.data = client;
    client->handles = 1;
    server->references++;
    server->connections++;
    client->next = server->clients;
    server->clients = client;
    if (uv_accept(stream, (uv_stream_t *)&client->tcp) != 0 || server->closing || server->connections > server->max_connections) {
        close_client(client);
        return;
    }
    if (uv_timer_init(uv_handle_get_loop((uv_handle_t *)stream), &client->timer) != 0) { close_client(client); return; }
    client->timer.data = client;
    client->handles = 2;
    if (uv_timer_start(&client->timer, client_timeout, server->timeout_ms, 0) != 0 ||
        uv_read_start((uv_stream_t *)&client->tcp, allocate_buffer, read_client) != 0) close_client(client);
}
int hao_http_server_valid_number(double value) {
    return isfinite(value) && value >= 0 && value <= 9007199254740991.0 && floor(value) == value;
}
static double number_property(JSContext *ctx, JSValueConst object, const char *key) {
    JSValue value = JS_GetPropertyStr(ctx, object, key);
    double result = -1;
    if (JS_IsNumber(value)) JS_ToFloat64(ctx, &result, value);
    JS_FreeValue(ctx, value);
    return result;
}
static JSValue serve_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !JS_IsObject(argv[0]) || !JS_IsFunction(ctx, argv[1]))
        return JS_ThrowTypeError(ctx, "http.serve requires options and a callback");
    JSValue host_value = JS_GetPropertyStr(ctx, argv[0], "hostname");
    const char *hostname = JS_ToCString(ctx, host_value);
    double port = number_property(ctx, argv[0], "port");
    double max_connections = number_property(ctx, argv[0], "maxConnections");
    double timeout_ms = number_property(ctx, argv[0], "requestTimeoutMs");
    int limits_error = !hao_http_server_valid_number(port) ? 1 :
        !hao_http_server_valid_number(max_connections) ? 2 :
        !hao_http_server_valid_number(timeout_ms) ? 3 :
        hao_http_server_limits_error(port, max_connections, timeout_ms);
    if (limits_error) {
        if (hostname) JS_FreeCString(ctx, hostname);
        JS_FreeValue(ctx, host_value);
        const char *messages[] = {"", "Invalid port", "Invalid connection limit", "Invalid timeout", "Invalid server limits"};
        return JS_ThrowTypeError(ctx, "%s", messages[limits_error]);
    }
    if (!hostname) {
        if (hostname) JS_FreeCString(ctx, hostname);
        JS_FreeValue(ctx, host_value);
        return JS_ThrowTypeError(ctx, "Invalid hostname");
    }
    struct sockaddr_in address;
    if (uv_ip4_addr(hostname, (int)port, &address) != 0) {
        JS_FreeCString(ctx, hostname);
        JS_FreeValue(ctx, host_value);
        return JS_ThrowTypeError(ctx, "hostname must be an IPv4 address");
    }
    JS_FreeCString(ctx, hostname);
    JS_FreeValue(ctx, host_value);
    HaoServer *server = hao_calloc(1, sizeof(*server));
    if (!server) return JS_ThrowOutOfMemory(ctx);
    server->ctx = ctx;
    server->callback = JS_DupValue(ctx, argv[1]);
    server->id = next_id++;
    server->max_connections = (unsigned)max_connections;
    server->timeout_ms = (uint64_t)timeout_ms;
    server->references = 1;
    uv_loop_t *loop = hao_runtime_loop(ctx);
    if (!loop || uv_tcp_init(loop, &server->listener) != 0) {
        JS_FreeValue(ctx, server->callback); hao_free(server);
        return JS_ThrowInternalError(ctx, "unable to initialize HTTP server");
    }
    server->listener.data = server;
    if (uv_tcp_bind(&server->listener, (const struct sockaddr *)&address, 0) != 0 ||
        uv_listen((uv_stream_t *)&server->listener, 128, accept_client) != 0) {
        server->closing = true;
        uv_close((uv_handle_t *)&server->listener, listener_closed);
        return JS_ThrowInternalError(ctx, "unable to bind HTTP server");
    }
    struct sockaddr_storage bound;
    int bound_size = sizeof(bound);
    if (uv_tcp_getsockname(&server->listener, (struct sockaddr *)&bound, &bound_size) != 0) {
        server->closing = true;
        uv_close((uv_handle_t *)&server->listener, listener_closed);
        return JS_ThrowInternalError(ctx, "unable to inspect HTTP server port");
    }
    server->next = servers;
    servers = server;
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "id", JS_NewInt64(ctx, server->id));
    JS_SetPropertyStr(ctx, result, "port", JS_NewInt32(ctx, ntohs(((struct sockaddr_in *)&bound)->sin_port)));
    return result;
}
static JSValue stop_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc && JS_ToInt64(ctx, &id, argv[0]) == 0) {
        HaoServer *server = find_server(id);
        if (server && server->ctx == ctx) stop_server(server);
    }
    return JS_UNDEFINED;
}
static JSValue unref_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (!argc || JS_ToInt64(ctx, &id, argv[0]) < 0) return JS_ThrowTypeError(ctx, "HTTP server id required");
    HaoServer *server = find_server(id);
    if (!server || server->ctx != ctx || server->closing) return JS_ThrowTypeError(ctx, "invalid HTTP server id");
    uv_unref((uv_handle_t *)&server->listener);
    return JS_UNDEFINED;
}
static JSValue pause_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc && JS_ToInt64(ctx, &id, argv[0]) == 0) {
        HaoClient *client = find_client(id);
        if (client && client->server->ctx == ctx) uv_read_stop((uv_stream_t *)&client->tcp);
    }
    return JS_UNDEFINED;
}
static void wrote_client(uv_write_t *request, int status) {
    (void)status;
    HaoWrite *write = request->data;
    close_client(write->client);
    hao_free(write->bytes);
    hao_free(write);
}
static JSValue respond_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 2 || JS_ToInt64(ctx, &id, argv[0]) != 0) return JS_ThrowTypeError(ctx, "invalid HTTP client id");
    HaoClient *client = find_client(id);
    if (!client || client->server->ctx != ctx || client->responding) return JS_UNDEFINED;
    size_t offset = 0, length = 0, total = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, argv[1], &offset, &length, NULL);
    if (JS_IsException(buffer)) return buffer;
    uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
    if (!bytes || offset > total || length > total - offset) {
        JS_FreeValue(ctx, buffer);
        return JS_ThrowTypeError(ctx, "response must be Uint8Array");
    }
    HaoWrite *write = hao_alloc(sizeof(*write));
    if (!write) { JS_FreeValue(ctx, buffer); return JS_ThrowOutOfMemory(ctx); }
    write->bytes = hao_alloc(length ? length : 1);
    if (!write->bytes) { hao_free(write); JS_FreeValue(ctx, buffer); return JS_ThrowOutOfMemory(ctx); }
    memcpy(write->bytes, bytes + offset, length);
    JS_FreeValue(ctx, buffer);
    write->client = client;
    write->request.data = write;
    uv_buf_t output = uv_buf_init(write->bytes, (unsigned int)length);
    client->responding = true;
    uv_read_stop((uv_stream_t *)&client->tcp);
    if (uv_write(&write->request, (uv_stream_t *)&client->tcp, &output, 1, wrote_client) != 0) {
        client->responding = false;
        hao_free(write->bytes); hao_free(write);
        close_client(client);
        return JS_ThrowInternalError(ctx, "HTTP response write failed");
    }
    return JS_UNDEFINED;
}
static JSValue encode_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (!argc) return JS_ThrowTypeError(ctx, "text required");
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, argv[0]);
    if (!text) return JS_EXCEPTION;
    JSValue result = bytes_value(ctx, text, length);
    JS_FreeCString(ctx, text);
    return result;
}
static JSValue decode_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (!argc) return JS_ThrowTypeError(ctx, "bytes required");
    size_t offset = 0, length = 0, total = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, argv[0], &offset, &length, NULL);
    if (JS_IsException(buffer)) return buffer;
    uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, buffer);
    JSValue result = bytes && offset <= total && length <= total - offset
        ? JS_NewStringLen(ctx, (const char *)bytes + offset, length)
        : JS_ThrowTypeError(ctx, "bytes must be Uint8Array");
    JS_FreeValue(ctx, buffer);
    return result;
}
void hao_install_http_server_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_http_serveNative", JS_NewCFunction(ctx, serve_native, "serveNative", 2));
    JS_SetPropertyStr(ctx, global, "__hao_http_unrefServerNative", JS_NewCFunction(ctx, unref_native, "unrefServerNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_stopServerNative", JS_NewCFunction(ctx, stop_native, "stopServerNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_pauseClientNative", JS_NewCFunction(ctx, pause_native, "pauseClientNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_respondNative", JS_NewCFunction(ctx, respond_native, "respondNative", 2));
    JS_SetPropertyStr(ctx, global, "__hao_http_encodeTextNative", JS_NewCFunction(ctx, encode_native, "encodeTextNative", 1));
    JS_SetPropertyStr(ctx, global, "__hao_http_decodeTextNative", JS_NewCFunction(ctx, decode_native, "decodeTextNative", 1));
}

/* JavaScript process adapter. */
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

/* Notebook cell evaluation. */
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

/* Test runner hooks. */
int hao_runtime_start_tests(uintptr_t handle, const char *grep, size_t grep_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__hao_test_grep", JS_NewStringLen(ctx, grep, grep_len));
    JS_FreeValue(ctx, global);
    const char *source = "globalThis.__hao_test_run()";
    JSValue result = JS_Eval(ctx, source, strlen(source), "<hao-test-runner>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        hao_runtime_print_exception(ctx);
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

void hao_test_print_failure(JSContext *ctx, JSValueConst error, const char *path) {
    JSValue detail = JS_GetPropertyStr(ctx, error, "message");
    const char *message = JS_IsUndefined(detail) ? JS_ToCString(ctx, error) : JS_ToCString(ctx, detail);
    fprintf(stderr, "%s module %s\n  %s\n",
            hao_test_reporter_ansi() ? "\x1b[31m✕\x1b[0m" : "✕",
            path, message ? message : "[uninitialized]");
    if (message) JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, detail);
}

int hao_runtime_drain_test(uintptr_t handle, const char *path, size_t length) {
    HaoRuntime *host = (HaoRuntime *)handle;
    char *name = hao_alloc(length + 1);
    if (!name) return -1;
    memcpy(name, path, length);
    name[length] = 0;
    JSContext *job_ctx = NULL;
    int result;
    int ran_jobs = 0;
    while ((result = JS_ExecutePendingJob(host->runtime, &job_ctx)) > 0) ran_jobs = 1;
    if (result < 0) {
        JSValue error = JS_GetException(job_ctx);
        hao_test_print_failure(job_ctx, error, name);
        JS_FreeValue(job_ctx, error);
        hao_free(name);
        return -1;
    }
    if (host->has_rejection) {
        hao_test_print_failure(host->rejection_context, host->rejection, name);
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
        hao_free(name);
        return -1;
    }
    hao_free(name);
    return ran_jobs;
}
