#include "../runtime_host.h"
#include <limits.h>
#include <stdlib.h>

struct HaoTimer {
    uv_timer_t handle;
    HaoRuntime *host;
    JSValue callback;
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
        uv_close((uv_handle_t *)&timer->handle, hao_timer_closed);
    }
}
