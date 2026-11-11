#include "runner.h"
#include "../global/console.h"
#include "../runtime_allocator.h"
#include "../runtime_host.h"
#include "../runtime_internal.h"
#include <quickjs.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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
