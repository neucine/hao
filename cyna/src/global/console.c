#include "../runtime_host.h"
#include "../runtime_allocator.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hao_capture_append(char **buffer, size_t *length, size_t *capacity,
                              const char *text, size_t count) {
    const size_t limit = 16 * 1024 * 1024;
    if (count > limit - *length) return -1;
    if (*length + count > *capacity) {
        size_t next_capacity = *capacity ? *capacity : 256;
        while (next_capacity < *length + count) next_capacity *= 2;
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
            if (status != 0) { JS_FreeValue(ctx, inspect); return JS_ThrowInternalError(ctx, "captured output exceeds 16 MiB"); }
        } else {
            fwrite(text, 1, text_length, stream);
            JS_FreeCString(ctx, text);
            JS_FreeValue(ctx, formatted);
        }
    }
    JS_FreeValue(ctx, inspect);
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
