#ifndef HAO_PROCESS_EXECUTE_H
#define HAO_PROCESS_EXECUTE_H

#include <stddef.h>

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

#endif
