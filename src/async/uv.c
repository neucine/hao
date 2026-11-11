#include "uv.h"
#include <uv.h>
#include "../runtime_allocator.h"
#include <stdlib.h>

uv_loop_t *hao_async_uv_new(void) {
    uv_loop_t *loop = hao_alloc(uv_loop_size());
    if (!loop) return NULL;
    if (uv_loop_init(loop) != 0) {
        hao_free(loop);
        return NULL;
    }
    return loop;
}

void hao_async_uv_free(uv_loop_t *loop) {
    if (!loop) return;
    while (uv_loop_close(loop) == UV_EBUSY) {
        uv_run(loop, UV_RUN_DEFAULT);
    }
    hao_free(loop);
}
