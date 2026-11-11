#ifndef HAO_RUNTIME_INTERNAL_H
#define HAO_RUNTIME_INTERNAL_H

#include <quickjs.h>

void hao_runtime_print_value(JSContext *ctx, JSValueConst error);
void hao_runtime_print_exception(JSContext *ctx);

#endif
