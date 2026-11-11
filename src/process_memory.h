#ifndef HAO_PROCESS_MEMORY_H
#define HAO_PROCESS_MEMORY_H
#include <stdint.h>
typedef struct {
    uint64_t resident_bytes;
    uint64_t physical_footprint_bytes;
} HaoProcessMemory;
HaoProcessMemory hao_process_memory_snapshot(void);
#endif
