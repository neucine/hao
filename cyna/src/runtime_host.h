#ifndef HAO_RUNTIME_HOST_H
#define HAO_RUNTIME_HOST_H

#include <quickjs.h>
#include <uv.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct HaoSourceModule {
    char *name;
    char *source;
    size_t source_len;
    struct HaoSourceModule *next;
} HaoSourceModule;

typedef struct HaoTimer HaoTimer;

uv_loop_t *hao_async_uv_new(void);
void hao_async_uv_free(uv_loop_t *loop);
int hao_async_uv_run_once(uv_loop_t *loop);
int hao_async_uv_run_nowait(uv_loop_t *loop);

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
    char *embed_error;
} HaoRuntime;

void hao_install_console_globals(JSContext *ctx, JSValue global);
void hao_install_timer_globals(JSContext *ctx, JSValue global);
void hao_cleanup_timers(HaoRuntime *host);
char *hao_normalize_module(JSContext *ctx, const char *base, const char *specifier, void *opaque);
JSModuleDef *hao_load_module(JSContext *ctx, const char *name, void *opaque);
void hao_module_cleanup(HaoRuntime *host);

#endif
