#ifndef HAO_SUPPORT_H
#define HAO_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    size_t active_size;
    size_t peak_size;
    size_t allocated_size;
    size_t freed_size;
    uint64_t allocation_count;
    uint64_t free_count;
} HaoAllocatorStats;

void *hao_alloc(size_t size);
void *hao_calloc(size_t count, size_t size);
void *hao_realloc(void *pointer, size_t size);
void hao_free(void *pointer);
char *hao_strdup(const char *text);
char *hao_strndup(const char *text, size_t length);
HaoAllocatorStats hao_allocator_stats(void);

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
void hao_process_memory_snapshot(uint64_t *resident_bytes, uint64_t *physical_footprint_bytes);

#endif
