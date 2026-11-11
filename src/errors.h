#ifndef HAO_ERRORS_H
#define HAO_ERRORS_H
#include <stddef.h>
#include <quickjs.h>
int hao_install_runtime_error(void *ctx);
int hao_error_eval(void *ctx, const unsigned char *source, size_t length);
void hao_error_install_stack_capture(void *ctx);
#endif
