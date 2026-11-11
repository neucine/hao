#ifndef HAO_CYNA_EXPORTS_H
#define HAO_CYNA_EXPORTS_H

#include <stddef.h>
#include "std/process/execute.h"

/* Exported only by hao_abi.cy, which delegates to the Cyna feature modules. */
int hao_resolve_package(const unsigned char *base, const unsigned char *specifier,
                        unsigned char *output, size_t capacity);
size_t hao_addon_name_length(const unsigned char *specifier, const unsigned char *path);
int hao_addon_write_name(const unsigned char *specifier, const unsigned char *path,
                         unsigned char *output, size_t capacity);
int hao_fs_exists(const unsigned char *path);
unsigned char *hao_fs_read_alloc(const unsigned char *path, size_t length, size_t limit);
int hao_fs_write(const unsigned char *path, const unsigned char *data, size_t length);
int hao_process_run_json(const unsigned char *options, size_t options_len,
                         unsigned char *stdout_output, unsigned char *stderr_output,
                         size_t capacity, HaoRunResult *result);

#endif
