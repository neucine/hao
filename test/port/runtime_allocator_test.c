#include "../../src/bridge/allocator.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

int main(void) {
    unsigned char *bytes = hao_calloc(4, 8);
    assert(bytes);
    for (int i = 0; i < 32; i++) assert(bytes[i] == 0);
    assert(((uintptr_t)bytes % _Alignof(max_align_t)) == 0);
    HaoAllocatorStats first = hao_allocator_stats();
    assert(first.active_size == 32 && first.peak_size == 32);
    assert(first.allocated_size == 32 && first.allocation_count == 1);

    bytes = hao_realloc(bytes, 64);
    assert(bytes);
    HaoAllocatorStats grown = hao_allocator_stats();
    assert(grown.active_size == 64 && grown.peak_size == 64);
    assert(grown.allocated_size == 64 && grown.allocation_count == 1);
    assert(hao_realloc(bytes, SIZE_MAX) == NULL);
    assert(hao_calloc(SIZE_MAX, 2) == NULL);
    HaoAllocatorStats rejected = hao_allocator_stats();
    assert(rejected.active_size == 64 && rejected.allocated_size == 64);
    assert(rejected.allocation_count == 1);

    bytes = hao_realloc(bytes, 16);
    assert(bytes);
    HaoAllocatorStats shrunk = hao_allocator_stats();
    assert(shrunk.active_size == 16 && shrunk.freed_size == 48);
    hao_free(bytes);
    HaoAllocatorStats ended = hao_allocator_stats();
    assert(ended.active_size == 0 && ended.freed_size == 64);
    assert(ended.free_count == 1);

    char *copy = hao_strdup("hao");
    assert(copy && strcmp(copy, "hao") == 0);
    hao_free(copy);
    assert(hao_allocator_stats().active_size == 0);
    char *bounded = hao_strndup("abcdef", 3);
    assert(bounded && strcmp(bounded, "abc") == 0);
    hao_free(bounded);
    return 0;
}
