#include "../../src/bridge/async/uv.h"
#include <stdio.h>

static int fired;
static int closed;

static void on_closed(uv_handle_t *handle) {
    (void)handle;
    closed++;
}

static void on_timer(uv_timer_t *timer) {
    fired++;
    uv_close((uv_handle_t *)timer, on_closed);
}

int main(void) {
    uv_loop_t *loop = hao_async_uv_new();
    if (!loop || hao_async_uv_run_nowait(loop) != 0) return 1;
    uv_timer_t first;
    if (uv_timer_init(loop, &first) != 0 ||
        uv_timer_start(&first, on_timer, 1, 0) != 0) return 2;
    if (hao_async_uv_run_once(loop) < 0 || fired != 1) return 3;
    hao_async_uv_free(loop);
    if (closed != 1) return 4;

    loop = hao_async_uv_new();
    if (!loop) return 5;
    uv_timer_t pending, cancelled;
    if (uv_timer_init(loop, &pending) != 0 ||
        uv_timer_start(&pending, on_timer, 1, 0) != 0 ||
        uv_timer_init(loop, &cancelled) != 0 ||
        uv_timer_start(&cancelled, on_timer, 100, 0) != 0) return 6;
    if (uv_timer_stop(&cancelled) != 0) return 7;
    uv_close((uv_handle_t *)&cancelled, on_closed);
    hao_async_uv_free(loop);
    if (fired != 2 || closed != 3) return 8;

    loop = hao_async_uv_new();
    if (!loop) return 9;
    uv_timer_t ready;
    if (uv_timer_init(loop, &ready) != 0 ||
        uv_timer_start(&ready, on_timer, 0, 0) != 0) return 10;
    if (hao_async_uv_run_nowait(loop) < 0 || fired != 3) return 11;
    hao_async_uv_free(loop);
    if (closed != 4) return 12;
    puts("async loop ok");
    return 0;
}
