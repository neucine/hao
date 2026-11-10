#include <quickjs.h>
#include <uv.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct HaoSourceModule {
    char *name;
    char *source;
    size_t source_len;
    struct HaoSourceModule *next;
} HaoSourceModule;

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
} HaoRuntime;

struct HaoTimer {
    uv_timer_t handle;
    HaoRuntime *host;
    JSValue callback;
    uint32_t id;
    HaoTimer *next;
};

extern char *hao_transpile_types_for_path(const char *source, const char *source_path);
extern char *hao_transpiler_last_error(void);
extern void hao_transpiler_free(char *text);

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
        JS_ThrowReferenceError(ctx, "Unsupported module specifier: %s", specifier);
        return NULL;
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
    HaoRuntime *host = opaque;
    HaoSourceModule *module = hao_find_module(host, name);
    if (module) {
        JSValue compiled = JS_Eval(ctx, module->source, module->source_len, name,
                                   JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
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

static JSValue hao_console_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    for (int i = 0; i < argc; ++i) {
        if (i) fputc(' ', stdout);
        const char *text = JS_ToCString(ctx, argv[i]);
        if (text) {
            fputs(text, stdout);
            JS_FreeCString(ctx, text);
        }
    }
    fputc('\n', stdout);
    return JS_UNDEFINED;
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
    HaoRuntime *host = calloc(1, sizeof(*host));
    if (!host) return 0;
    host->runtime = JS_NewRuntime();
    if (!host->runtime) {
        free(host);
        return 0;
    }
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
    JS_SetPropertyStr(host->context, global, "console", console);
    JS_SetPropertyStr(host->context, global, "setTimeout", JS_NewCFunction(host->context, hao_set_timeout, "setTimeout", 2));
    JS_SetPropertyStr(host->context, global, "clearTimeout", JS_NewCFunction(host->context, hao_clear_timeout, "clearTimeout", 1));
    JS_FreeValue(host->context, global);
    return (uintptr_t)host;
}

void hao_runtime_free(uintptr_t handle) {
    if (!handle) return;
    HaoRuntime *host = (HaoRuntime *)handle;
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

int hao_runtime_eval(uintptr_t handle, const char *source, size_t source_len,
                     const char *filename, size_t filename_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (filename_len == SIZE_MAX || source_len == SIZE_MAX) return 1;
    char *name = malloc(filename_len + 1);
    if (!name) return 1;
    memcpy(name, filename, filename_len);
    name[filename_len] = 0;
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
