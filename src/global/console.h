#ifndef HAO_GLOBAL_CONSOLE_H
#define HAO_GLOBAL_CONSOLE_H

#include <stddef.h>
#include <stdint.h>

int hao_test_reporter_ansi(void);
int hao_global_install_console(uintptr_t handle);
void hao_test_print_load(size_t index, size_t total, const unsigned char *path, size_t length);

#endif
