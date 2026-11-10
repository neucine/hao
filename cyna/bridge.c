#include <quickjs.h>
#include <uv.h>
#include <stdbool.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct HaoSourceModule {
    char *name;
    char *source;
    size_t source_len;
    struct HaoSourceModule *next;
} HaoSourceModule;

static bool positive_size_env(const char *name, size_t *out, bool *present) {
    const char *value = getenv(name);
    *present = value && *value;
    if (!*present) return true;
    if (*value == '-' || *value == '+' || *value == ' ') return false;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno || !end || *end || parsed == 0 || parsed > SIZE_MAX) return false;
    *out = (size_t)parsed;
    return true;
}

typedef struct HaoTimer HaoTimer;

typedef struct HaoRuntime {
    JSRuntime *runtime;
    JSContext *context;
    uv_loop_t *loop;
    JSContext *rejection_context;
    JSValue rejection;
    bool has_rejection;
    JSValue callback_error;
    bool has_callback_error;
    uint32_t next_timer_id;
    HaoTimer *timers;
    HaoSourceModule *modules;
    bool capture_active;
    int capture_target;
    char *capture_stdout;
    char *capture_stderr;
    size_t capture_stdout_len, capture_stderr_len;
    size_t capture_stdout_cap, capture_stderr_cap;
} HaoRuntime;

struct HaoTimer {
    uv_timer_t handle;
    HaoRuntime *host;
    JSValue callback;
    uint32_t id;
    HaoTimer *next;
};

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
void hao_runtime_free(uintptr_t handle);

static HaoSourceModule *hao_find_module(HaoRuntime *host, const char *name) {
    for (HaoSourceModule *module = host->modules; module; module = module->next) {
        if (strcmp(module->name, name) == 0) return module;
    }
    return NULL;
}

int hao_runtime_register(uintptr_t handle, const char *name, size_t name_len,
                         const char *source, size_t source_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (name_len == SIZE_MAX || source_len == SIZE_MAX) return 1;
    HaoSourceModule *module = calloc(1, sizeof(*module));
    if (!module) return 1;
    module->name = malloc(name_len + 1);
    module->source = malloc(source_len + 1);
    if (!module->name || !module->source) {
        free(module->name);
        free(module->source);
        free(module);
        return 1;
    }
    memcpy(module->name, name, name_len);
    module->name[name_len] = 0;
    memcpy(module->source, source, source_len);
    module->source[source_len] = 0;
    module->source_len = source_len;
    if (hao_find_module(host, module->name)) {
        free(module->name);
        free(module->source);
        free(module);
        return 1;
    }
    module->next = host->modules;
    host->modules = module;
    return 0;
}

static char *hao_normalize_module(JSContext *ctx, const char *base,
                                   const char *specifier, void *opaque) {
    HaoRuntime *host = opaque;
    if (hao_find_module(host, specifier)) {
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
            JS_ThrowReferenceError(ctx, "Cannot resolve package: %s", specifier);
            return NULL;
        }
        candidate[candidate_len] = 0;
        char *resolved = realpath((const char *)candidate, NULL);
        if (!resolved) {
            JS_ThrowReferenceError(ctx, "Package entry not found: %s", specifier);
            return NULL;
        }
        size_t len = strlen(resolved);
        const char *extension = strrchr(resolved, '.');
        bool addon = extension && (!strcmp(extension, ".dylib") || !strcmp(extension, ".so") ||
                                   !strcmp(extension, ".dll") || !strcmp(extension, ".node"));
        if (addon) len += strlen(specifier) + 7;
        char *normalized = js_malloc(ctx, len + 1);
        if (normalized) {
            if (addon) snprintf(normalized, len + 1, "addon:%s\n%s", specifier, resolved);
            else memcpy(normalized, resolved, len + 1);
        }
        free(resolved);
        return normalized;
    }
    const char *slash = strrchr(base, '/');
    size_t dir_len = slash ? (size_t)(slash - base) : 1;
    size_t spec_len = strlen(specifier);
    char *joined = malloc(dir_len + spec_len + 3);
    if (!joined) return NULL;
    if (slash) memcpy(joined, base, dir_len);
    else joined[0] = '.';
    joined[dir_len] = '/';
    memcpy(joined + dir_len + 1, specifier, spec_len + 1);
    char *resolved = realpath(joined, NULL);
    free(joined);
    if (!resolved) {
        JS_ThrowReferenceError(ctx, "Module not found: %s", specifier);
        return NULL;
    }
    size_t len = strlen(resolved);
    char *normalized = js_malloc(ctx, len + 1);
    if (normalized) memcpy(normalized, resolved, len + 1);
    free(resolved);
    return normalized;
}

static JSModuleDef *hao_load_module(JSContext *ctx, const char *name, void *opaque) {
    if (strncmp(name, "addon:", 6) == 0) return hao_load_addon(ctx, name);
    HaoRuntime *host = opaque;
    HaoSourceModule *module = hao_find_module(host, name);
    if (module) {
        size_t name_len = strlen(name);
        char *typescript_path = malloc(name_len + 4);
        if (!typescript_path) return NULL;
        memcpy(typescript_path, name, name_len);
        memcpy(typescript_path + name_len, ".ts", 4);
        char *transformed = hao_transpile_types_for_path(module->source, typescript_path);
        free(typescript_path);
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
    FILE *file = fopen(name, "rb");
    if (!file) {
        JS_ThrowReferenceError(ctx, "Module not found: %s", name);
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size < 0 || size > 10 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    char *source = malloc((size_t)size + 1);
    if (!source) {
        fclose(file);
        return NULL;
    }
    size_t read_count = fread(source, 1, (size_t)size, file);
    fclose(file);
    if (read_count != (size_t)size) {
        free(source);
        return NULL;
    }
    source[size] = 0;
    char *transformed = hao_transpile_types_for_path(source, name);
    free(source);
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

static int hao_capture_append(char **buffer, size_t *length, size_t *capacity,
                              const char *text, size_t count) {
    const size_t limit = 16 * 1024 * 1024;
    if (count > limit - *length) return -1;
    if (*length + count > *capacity) {
        size_t next_capacity = *capacity ? *capacity : 256;
        while (next_capacity < *length + count) next_capacity *= 2;
        char *next = realloc(*buffer, next_capacity);
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
    for (int i = 0; i < argc; ++i) {
        if (i) {
            if (capture) {
                if (hao_capture_append(buffer, length, capacity, " ", 1) != 0) return JS_ThrowOutOfMemory(ctx);
            } else fputc(' ', stream);
        }
        const char *text = JS_ToCString(ctx, argv[i]);
        if (!text) return JS_EXCEPTION;
        if (capture) {
            int status = hao_capture_append(buffer, length, capacity, text, strlen(text));
            JS_FreeCString(ctx, text);
            if (status != 0) return JS_ThrowInternalError(ctx, "captured output exceeds 16 MiB");
        } else {
            fputs(text, stream);
            JS_FreeCString(ctx, text);
        }
    }
    if (capture) {
        if (hao_capture_append(buffer, length, capacity, "\n", 1) != 0) return JS_ThrowInternalError(ctx, "captured output exceeds 16 MiB");
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
    size_t total = host->capture_stdout_len + host->capture_stderr_len;
    char *combined = malloc(total ? total : 1);
    if (!combined) { JS_FreeValue(ctx, result); return JS_ThrowOutOfMemory(ctx); }
    if (host->capture_stdout_len) memcpy(combined, host->capture_stdout, host->capture_stdout_len);
    if (host->capture_stderr_len) memcpy(combined + host->capture_stdout_len, host->capture_stderr, host->capture_stderr_len);
    JS_SetPropertyStr(ctx, result, "combined", JS_NewStringLen(ctx, combined, total));
    free(combined);
    return result;
}

static void hao_print_value(JSContext *ctx, JSValueConst error) {
    JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
    const char *text = JS_ToCString(ctx, error);
    if (text) {
        fprintf(stderr, "%s\n", text);
        JS_FreeCString(ctx, text);
    }
    if (!JS_IsUndefined(stack)) {
        text = JS_ToCString(ctx, stack);
        if (text) {
            fprintf(stderr, "%s\n", text);
            JS_FreeCString(ctx, text);
        }
    }
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
    free(timer);
}

static void hao_timer_fired(uv_timer_t *handle) {
    HaoTimer *timer = handle->data;
    HaoRuntime *host = timer->host;
    hao_unlink_timer(host, timer);
    JSValue result = JS_Call(host->context, timer->callback, JS_UNDEFINED, 0, NULL);
    if (JS_IsException(result)) {
        JSValue error = JS_GetException(host->context);
        if (!host->has_callback_error) {
            host->callback_error = error;
            host->has_callback_error = true;
        } else {
            JS_FreeValue(host->context, error);
        }
    }
    JS_FreeValue(host->context, result);
    JS_FreeValue(host->context, timer->callback);
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
    HaoTimer *timer = calloc(1, sizeof(*timer));
    if (!timer) return JS_ThrowOutOfMemory(ctx);
    if (uv_timer_init(host->loop, &timer->handle) != 0) {
        free(timer);
        return JS_ThrowInternalError(ctx, "Timer initialization failed");
    }
    timer->host = host;
    timer->handle.data = timer;
    timer->callback = JS_DupValue(ctx, argv[0]);
    timer->id = host->next_timer_id++;
    if (host->next_timer_id == 0 || host->next_timer_id > INT32_MAX) host->next_timer_id = 1;
    timer->next = host->timers;
    host->timers = timer;
    if (uv_timer_start(&timer->handle, hao_timer_fired, delay == 0 ? 1 : (uint64_t)delay, 0) != 0) {
        hao_unlink_timer(host, timer);
        JS_FreeValue(ctx, timer->callback);
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
    if (JS_ToInt32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    if (id <= 0) return JS_UNDEFINED;
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    for (HaoTimer *timer = host->timers; timer; timer = timer->next) {
        if (timer->id == (uint32_t)id) {
            hao_unlink_timer(host, timer);
            uv_timer_stop(&timer->handle);
            JS_FreeValue(ctx, timer->callback);
            uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
            break;
        }
    }
    return JS_UNDEFINED;
}

uintptr_t hao_runtime_new(void) {
    size_t stack_size = 8 * 1024 * 1024, gc_threshold = 0, thread_pool_size = 0;
    bool stack_present = false, gc_present = false, pool_present = false;
    if (!positive_size_env("RUNTIME_QJS_STACK_SIZE", &stack_size, &stack_present) ||
        !positive_size_env("RUNTIME_QJS_GC_THRESHOLD", &gc_threshold, &gc_present) ||
        !positive_size_env("RUNTIME_LIBUV_THREADPOOL_SIZE", &thread_pool_size, &pool_present)) {
        fprintf(stderr, "Invalid Hao runtime size setting\n");
        return 0;
    }
    if (pool_present) {
        char buffer[32];
        snprintf(buffer, sizeof(buffer), "%zu", thread_pool_size);
        if (setenv("UV_THREADPOOL_SIZE", buffer, 1) != 0) return 0;
    }
    HaoRuntime *host = calloc(1, sizeof(*host));
    if (!host) return 0;
    host->runtime = JS_NewRuntime();
    if (!host->runtime) {
        free(host);
        return 0;
    }
    JS_SetMaxStackSize(host->runtime, stack_size);
    if (gc_present) JS_SetGCThreshold(host->runtime, gc_threshold);
    JS_SetHostPromiseRejectionTracker(host->runtime, hao_on_rejection, host);
    host->context = JS_NewContext(host->runtime);
    if (!host->context) {
        JS_FreeRuntime(host->runtime);
        free(host);
        return 0;
    }
    host->loop = malloc(uv_loop_size());
    if (!host->loop || uv_loop_init(host->loop) != 0) {
        free(host->loop);
        JS_FreeContext(host->context);
        JS_FreeRuntime(host->runtime);
        free(host);
        return 0;
    }
    host->next_timer_id = 1;
    JS_SetContextOpaque(host->context, host);
    JS_SetModuleLoaderFunc(host->runtime, hao_normalize_module, hao_load_module, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JSValue console = JS_NewObject(host->context);
    JS_SetPropertyStr(host->context, console, "log", JS_NewCFunction(host->context, hao_console_log, "log", 1));
    JS_SetPropertyStr(host->context, console, "error", JS_NewCFunction(host->context, hao_console_error, "error", 1));
    JS_SetPropertyStr(host->context, console, "warn", JS_NewCFunction(host->context, hao_console_error, "warn", 1));
    JS_SetPropertyStr(host->context, global, "console", console);
    JS_SetPropertyStr(host->context, global, "setTimeout", JS_NewCFunction(host->context, hao_set_timeout, "setTimeout", 2));
    JS_SetPropertyStr(host->context, global, "clearTimeout", JS_NewCFunction(host->context, hao_clear_timeout, "clearTimeout", 1));
    JS_SetPropertyStr(host->context, global, "__hao_test_beginCapture", JS_NewCFunction(host->context, hao_begin_capture, "beginCapture", 1));
    JS_SetPropertyStr(host->context, global, "__hao_test_endCapture", JS_NewCFunction(host->context, hao_end_capture, "endCapture", 0));
    hao_install_fs_globals(host->context, global);
    hao_install_process_globals(host->context, global);
    hao_install_http_globals(host->context, global);
    hao_install_http_server_globals(host->context, global);
    hao_install_telemetry_globals(host->context, global);
    hao_install_ffi_globals(host->context, global);
    JS_FreeValue(host->context, global);
    const char *runtime_error_source =
        "globalThis.RuntimeError = class RuntimeError extends Error {"
        "constructor(code, message) { super(message); this.name = 'RuntimeError'; this.code = code; }"
        "};";
    JSValue runtime_error_result = JS_Eval(host->context, runtime_error_source,
        strlen(runtime_error_source), "<runtime-errors>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(runtime_error_result)) {
        hao_print_exception(host->context);
        JS_FreeValue(host->context, runtime_error_result);
        hao_runtime_free((uintptr_t)host);
        return 0;
    }
    JS_FreeValue(host->context, runtime_error_result);
    return (uintptr_t)host;
}

void hao_runtime_free(uintptr_t handle) {
    if (!handle) return;
    HaoRuntime *host = (HaoRuntime *)handle;
    hao_http_server_cleanup(host->context);
    hao_ffi_cleanup(host->context);
    hao_addon_cleanup(host->context);
    hao_metric_cleanup(host->context);
    while (host->timers) {
        HaoTimer *timer = host->timers;
        hao_unlink_timer(host, timer);
        uv_timer_stop(&timer->handle);
        JS_FreeValue(host->context, timer->callback);
        uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
    }
    uv_run(host->loop, UV_RUN_DEFAULT);
    uv_loop_close(host->loop);
    free(host->loop);
    free(host->capture_stdout);
    free(host->capture_stderr);
    if (host->has_rejection) JS_FreeValue(host->rejection_context, host->rejection);
    if (host->has_callback_error) JS_FreeValue(host->context, host->callback_error);
    JS_FreeContext(host->context);
    JS_FreeRuntime(host->runtime);
    HaoSourceModule *module = host->modules;
    while (module) {
        HaoSourceModule *next = module->next;
        free(module->name);
        free(module->source);
        free(module);
        module = next;
    }
    free(host);
}

uv_loop_t *hao_runtime_loop(JSContext *ctx) {
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    return host ? host->loop : NULL;
}

int hao_runtime_eval(uintptr_t handle, const char *source, size_t source_len,
                     const char *filename, size_t filename_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (filename_len == SIZE_MAX || source_len == SIZE_MAX) return 1;
    char *name = malloc(filename_len + 1);
    if (!name) return 1;
    memcpy(name, filename, filename_len);
    name[filename_len] = 0;
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__hao_test_filePath", JS_NewStringLen(host->context, filename, filename_len));
    JS_FreeValue(host->context, global);
    char *input = malloc(source_len + 1);
    if (!input) {
        free(name);
        return 1;
    }
    memcpy(input, source, source_len);
    input[source_len] = 0;
    char *transformed = hao_transpile_types_for_path(input, name);
    free(input);
    if (!transformed) {
        char *error = hao_transpiler_last_error();
        if (error) {
            fprintf(stderr, "%s\n", error);
            hao_transpiler_free(error);
        }
        free(name);
        return 1;
    }
    JSValue result = JS_Eval(host->context, transformed, strlen(transformed), name, JS_EVAL_TYPE_MODULE);
    hao_transpiler_free(transformed);
    free(name);
    int status = 0;
    if (JS_IsException(result)) {
        hao_print_exception(host->context);
        status = 1;
    }
    JS_FreeValue(host->context, result);
    return status;
}

static char *hao_rewrite_cell_declarations(const char *source) {
    size_t length = strlen(source);
    char *output = malloc(length * 2 + 1);
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
        char *helper = malloc(helper_len);
        if (helper) snprintf(helper, helper_len,
            "import * as __hao_ns from %s; globalThis.__hao_jupyter_import = __hao_ns;", quoted_text);
        JS_FreeCString(ctx, quoted_text);
        JS_FreeValue(ctx, quoted);
        if (!helper) { JS_ThrowOutOfMemory(ctx); goto import_done; }
        char helper_name[4096];
        snprintf(helper_name, sizeof(helper_name), "%s.import.%u.ts", filename, i);
        JSValue imported = JS_Eval(ctx, helper, strlen(helper), helper_name, JS_EVAL_TYPE_MODULE);
        free(helper);
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
        char *buffer = malloc(length);
        if (buffer) {
            snprintf(buffer, length, "%s%s%s%s%s", label, message ? ": " : "",
                     message ? message : "", stack ? "\n" : "", stack ? stack : "");
            JS_FreeValue(ctx, text);
            text = JS_NewString(ctx, buffer);
            free(buffer);
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
        "Promise.resolve(globalThis.__hao_nb_async_promise).then("
        "value => { const s = globalThis.__hao_nb_async_state; s.value = value; s.ok = true; s.settled = true; },"
        "error => { const s = globalThis.__hao_nb_async_state; s.value = error; s.settled = true; });";
    JSValue setup = JS_Eval(ctx, bootstrap, sizeof(bootstrap) - 1,
                            "<hao-jupyter-await>", JS_EVAL_TYPE_GLOBAL);
    JSValue outcome = JS_UNDEFINED;
    if (JS_IsException(setup)) {
        outcome = setup;
    } else {
        JS_FreeValue(ctx, setup);
        bool completed = false;
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
            if (JS_ExecutePendingJob(host->runtime, &job_ctx) < 0) {
                JSValue error = JS_GetException(job_ctx);
                JS_Throw(ctx, error);
                outcome = JS_EXCEPTION;
                completed = true;
                break;
            }
            uv_run(host->loop, UV_RUN_NOWAIT);
            usleep(1000);
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
    char *input = malloc(source_len + 1);
    char *name = malloc(filename_len + 1);
    if (!input || !name) { free(input); free(name); return NULL; }
    memcpy(input, source, source_len); input[source_len] = 0;
    memcpy(name, filename, filename_len); name[filename_len] = 0;
    if (name[0] == '<') {
        char cwd[4096];
        if (!getcwd(cwd, sizeof(cwd))) { free(input); free(name); return NULL; }
        size_t needed = strlen(cwd) + filename_len + 10;
        char *absolute = malloc(needed);
        if (!absolute) { free(input); free(name); return NULL; }
        snprintf(absolute, needed, "%s/.%s.ts", cwd, name);
        free(name);
        name = absolute;
    }
    host->capture_stdout_len = host->capture_stderr_len = 0;
    host->capture_target = 3;
    host->capture_active = true;
    JSContext *ctx = host->context;
    char *transformed = hao_prepare_cell(ctx, input, name);
    free(input);
    JSValue result = JS_UNDEFINED;
    JSValue exception = JS_UNDEFINED;
    if (transformed) {
        result = JS_Eval(ctx, transformed, strlen(transformed), name, JS_EVAL_TYPE_GLOBAL);
        free(transformed);
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
    free(name);
    if (JS_IsUndefined(exception)) {
        JSContext *job_ctx = NULL;
        for (int i = 0; i < 10000; i++) {
            int jobs = JS_ExecutePendingJob(host->runtime, &job_ctx);
            if (jobs < 0) { exception = JS_GetException(job_ctx); break; }
            int io = uv_run(host->loop, UV_RUN_NOWAIT);
            if (jobs == 0 && io == 0) break;
        }
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
    const char *value = JS_ToCString(ctx, display);
    JS_SetPropertyStr(ctx, packet, "value", value ? JS_NewString(ctx, value) : JS_NULL);
    if (!JS_IsUndefined(mime)) JS_SetPropertyStr(ctx, packet, "mime", mime);
    JS_SetPropertyStr(ctx, packet, "error", JS_NewBool(ctx, !JS_IsUndefined(exception)));
    JS_SetPropertyStr(ctx, packet, "has_value", JS_NewBool(ctx, JS_IsUndefined(exception) && !JS_IsUndefined(result) && !JS_IsNull(result)));
    if (value) JS_FreeCString(ctx, value);
    JS_FreeValue(ctx, display);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, exception);
    JSValue encoded = JS_JSONStringify(ctx, packet, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, packet);
    if (JS_IsException(encoded)) { JS_FreeValue(ctx, encoded); return NULL; }
    const char *text = JS_ToCString(ctx, encoded);
    char *copy = text ? strdup(text) : NULL;
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, encoded);
    return copy;
}

void hao_runtime_free_text(const char *text) { free((void *)text); }

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

int hao_runtime_discard_test_file(uintptr_t handle, const char *path, size_t path_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue discard = JS_GetPropertyStr(ctx, global, "__hao_test_discardFile");
    if (JS_IsUndefined(discard)) {
        JS_FreeValue(ctx, discard);
        JS_FreeValue(ctx, global);
        return 0;
    }
    JSValue argument = JS_NewStringLen(ctx, path, path_len);
    JSValue result = JS_Call(ctx, discard, global, 1, &argument);
    JS_FreeValue(ctx, argument);
    JS_FreeValue(ctx, discard);
    JS_FreeValue(ctx, global);
    if (JS_IsException(result)) {
        hao_print_exception(ctx);
        JS_FreeValue(ctx, result);
        return 1;
    }
    JS_FreeValue(ctx, result);
    return 0;
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

int hao_runtime_drain(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    JSContext *job_ctx = NULL;
    int result;
    int ran_jobs = 0;
    while ((result = JS_ExecutePendingJob(host->runtime, &job_ctx)) > 0) ran_jobs = 1;
    if (result < 0) {
        hao_print_exception(job_ctx);
        return -1;
    }
    if (host->has_rejection) {
        hao_print_value(host->rejection_context, host->rejection);
        JS_FreeValue(host->rejection_context, host->rejection);
        host->has_rejection = false;
        return -1;
    }
    return ran_jobs;
}

int hao_runtime_run_turn(uintptr_t handle) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (uv_loop_alive(host->loop) == 0) return 0;
    int result = uv_run(host->loop, UV_RUN_ONCE);
    if (result < 0) return -1;
    if (host->has_callback_error) {
        hao_print_value(host->context, host->callback_error);
        JS_FreeValue(host->context, host->callback_error);
        host->has_callback_error = false;
        return -1;
    }
    return 1;
}
