#include "runtime_allocator.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef union {
    max_align_t alignment;
    size_t size;
} AllocationHeader;

static _Atomic size_t active_size;
static _Atomic size_t peak_size;
static _Atomic size_t allocated_size;
static _Atomic size_t freed_size;
static _Atomic uint64_t allocation_count;
static _Atomic uint64_t free_count;

static void increase_active(size_t size) {
    size_t active = atomic_fetch_add(&active_size, size) + size;
    size_t peak = atomic_load(&peak_size);
    while (active > peak && !atomic_compare_exchange_weak(&peak_size, &peak, active)) {}
}

void *hao_alloc(size_t size) {
    if (size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *header = malloc(sizeof(*header) + size);
    if (!header) return NULL;
    header->size = size;
    atomic_fetch_add(&allocated_size, size);
    atomic_fetch_add(&allocation_count, 1);
    increase_active(size);
    return header + 1;
}

void *hao_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) return NULL;
    size_t bytes = count * size;
    void *pointer = hao_alloc(bytes);
    if (pointer) memset(pointer, 0, bytes);
    return pointer;
}

void *hao_realloc(void *pointer, size_t size) {
    if (!pointer) return hao_alloc(size);
    if (size > SIZE_MAX - sizeof(AllocationHeader)) return NULL;
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    size_t old_size = header->size;
    AllocationHeader *resized = realloc(header, sizeof(*header) + size);
    if (!resized) return NULL;
    resized->size = size;
    if (size > old_size) {
        size_t delta = size - old_size;
        atomic_fetch_add(&allocated_size, delta);
        increase_active(delta);
    } else if (old_size > size) {
        size_t delta = old_size - size;
        atomic_fetch_add(&freed_size, delta);
        atomic_fetch_sub(&active_size, delta);
    }
    return resized + 1;
}

void hao_free(void *pointer) {
    if (!pointer) return;
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    size_t size = header->size;
    atomic_fetch_add(&freed_size, size);
    atomic_fetch_add(&free_count, 1);
    atomic_fetch_sub(&active_size, size);
    free(header);
}

char *hao_strdup(const char *text) {
    size_t size = strlen(text) + 1;
    char *copy = hao_alloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}

HaoAllocatorStats hao_allocator_stats(void) {
    return (HaoAllocatorStats){
        atomic_load(&active_size), atomic_load(&peak_size),
        atomic_load(&allocated_size), atomic_load(&freed_size),
        atomic_load(&allocation_count), atomic_load(&free_count)
    };
}
