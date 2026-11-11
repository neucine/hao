#ifndef HAO_MODULE_H
#define HAO_MODULE_H

#include <stddef.h>
#include <stdint.h>

int hao_runtime_register(uintptr_t handle, const char *name, size_t name_len, const char *source, size_t source_len);

#endif
