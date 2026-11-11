#ifndef HAO_CYNA_EXPORTS_H
#define HAO_CYNA_EXPORTS_H

#include <stddef.h>
#include "std/process/execute.h"

/* Implemented by Cyna export c(...) functions in package.cy, fs.cy, and
   std/process/native.cy. This header is the C side of those ABI boundaries. */
int hao_resolve_package(const unsigned char *base, const unsigned char *specifier,
                        unsigned char *output, size_t capacity);
int hao_fs_exists(const unsigned char *path);
int hao_fs_write(const unsigned char *path, const unsigned char *data, size_t length);
int hao_process_run_json(const unsigned char *options, size_t options_len,
                         unsigned char *stdout_output, unsigned char *stderr_output,
                         size_t capacity, HaoRunResult *result);

#endif
