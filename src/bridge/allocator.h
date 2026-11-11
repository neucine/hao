#ifndef HAO_ALLOCATOR_H
#define HAO_ALLOCATOR_H

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

#endif
