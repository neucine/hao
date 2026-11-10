#include <quickjs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static void hao_print_exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
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
    JS_FreeValue(ctx, error);
}

int hao_eval(const char *source, size_t source_len, const char *filename, size_t filename_len) {
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) return 1;
    JSContext *ctx = JS_NewContext(runtime);
    if (!ctx) {
        JS_FreeRuntime(runtime);
        return 1;
    }
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log", JS_NewCFunction(ctx, hao_console_log, "log", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_FreeValue(ctx, global);

    char *name = malloc(filename_len + 1);
    if (!name) {
        JS_FreeContext(ctx);
        JS_FreeRuntime(runtime);
        return 1;
    }
    memcpy(name, filename, filename_len);
    name[filename_len] = 0;
    JSValue result = JS_Eval(ctx, source, source_len, name, JS_EVAL_TYPE_GLOBAL);
    free(name);
    int status = 0;
    if (JS_IsException(result)) {
        hao_print_exception(ctx);
        status = 1;
    }
    JS_FreeValue(ctx, result);
    if (!status) {
        JSContext *job_ctx = NULL;
        int job_result;
        while ((job_result = JS_ExecutePendingJob(runtime, &job_ctx)) > 0) {}
        if (job_result < 0) {
            hao_print_exception(job_ctx);
            status = 1;
        }
    }
    JS_FreeContext(ctx);
    JS_FreeRuntime(runtime);
    return status;
}
