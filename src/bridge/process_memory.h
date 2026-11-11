#ifndef HAO_PROCESS_MEMORY_H
#define HAO_PROCESS_MEMORY_H
#include <stdint.h>
void hao_process_memory_native(uint64_t *resident_bytes, uint64_t *physical_footprint_bytes);
void hao_process_memory_snapshot(uint64_t *resident_bytes, uint64_t *physical_footprint_bytes);
#endif
