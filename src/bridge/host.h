#ifndef HAO_HOST_H
#define HAO_HOST_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    size_t stdout_len;
    size_t stderr_len;
    int exit_code;
    int has_exit_code;
    int signal;
    int has_signal;
} HaoRunResult;

int hao_process_execute(const unsigned char *program, size_t program_len,
                        const unsigned char *args, size_t args_len, size_t args_count,
                        const unsigned char *cwd, size_t cwd_len,
                        unsigned char *stdout_output, unsigned char *stderr_output,
                        size_t capacity, HaoRunResult *result);

void hao_process_memory_native(uint64_t *resident_bytes, uint64_t *physical_footprint_bytes);

#endif
