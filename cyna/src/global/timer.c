#include "../runtime_host.h"
#include "../runtime_allocator.h"
#include <limits.h>
#include <stdlib.h>

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
    if (JS_ToInt32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
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
