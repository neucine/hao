#ifndef HAO_TEST_RUNNER_H
#define HAO_TEST_RUNNER_H

#include <quickjs.h>

void hao_test_print_failure(JSContext *ctx, JSValueConst error, const char *path);

#endif
