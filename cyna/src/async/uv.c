#include <uv.h>
#include <stdlib.h>

uv_loop_t *hao_async_uv_new(void) {
    uv_loop_t *loop = malloc(uv_loop_size());
    if (!loop) return NULL;
    if (uv_loop_init(loop) != 0) {
        free(loop);
        return NULL;
    }
    return loop;
}

void hao_async_uv_free(uv_loop_t *loop) {
    if (!loop) return;
    while (uv_loop_close(loop) == UV_EBUSY) {
        uv_run(loop, UV_RUN_DEFAULT);
    }
    free(loop);
}

int hao_async_uv_run_once(uv_loop_t *loop) {
    if (!loop || !uv_loop_alive(loop)) return 0;
    return uv_run(loop, UV_RUN_ONCE) < 0 ? -1 : 1;
}

int hao_async_uv_run_nowait(uv_loop_t *loop) {
    if (!loop || !uv_loop_alive(loop)) return 0;
    return uv_run(loop, UV_RUN_NOWAIT);
}
