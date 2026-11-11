#ifndef HAO_ASYNC_UV_H
#define HAO_ASYNC_UV_H
#include <uv.h>
uv_loop_t *hao_async_uv_new(void);
void hao_async_uv_free(uv_loop_t *loop);
int hao_async_uv_run_once(uv_loop_t *loop);
int hao_async_uv_run_nowait(uv_loop_t *loop);
#endif
