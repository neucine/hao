#include "process_memory.h"
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/task_info.h>
#endif

void hao_process_memory_native(uint64_t *resident_bytes, uint64_t *physical_footprint_bytes) {
    *resident_bytes = 0;
    *physical_footprint_bytes = 0;
#if defined(__APPLE__)
    mach_task_basic_info_data_t basic = {0};
    mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &basic_count) == KERN_SUCCESS)
        *resident_bytes = basic.resident_size;

    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vm_count) == KERN_SUCCESS)
        *physical_footprint_bytes = vm.phys_footprint;
#elif defined(__linux__)
    FILE *file = fopen("/proc/self/statm", "r");
    if (file) {
        unsigned long pages = 0, resident = 0;
        long page_size = sysconf(_SC_PAGESIZE);
        if (page_size > 0 && fscanf(file, "%lu %lu", &pages, &resident) == 2)
            *resident_bytes = (uint64_t)resident * (uint64_t)page_size;
        fclose(file);
    }
#endif
}
