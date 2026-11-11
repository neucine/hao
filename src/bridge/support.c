#define _DARWIN_C_SOURCE 1
#include "process_memory.h"
#include "runtime_allocator.h"
#include "std/process/execute.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/task_info.h>
#endif

/* Hao allocation accounting. */
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

char *hao_strndup(const char *text, size_t length) {
    size_t size = 0;
    while (size < length && text[size]) size++;
    if (size == SIZE_MAX) return NULL;
    char *copy = hao_alloc(size + 1);
    if (copy) {
        memcpy(copy, text, size);
        copy[size] = 0;
    }
    return copy;
}

HaoAllocatorStats hao_allocator_stats(void) {
    return (HaoAllocatorStats){
        atomic_load(&active_size), atomic_load(&peak_size),
        atomic_load(&allocated_size), atomic_load(&freed_size),
        atomic_load(&allocation_count), atomic_load(&free_count)
    };
}

/* Process memory counters. */
#if defined(__APPLE__)
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

/* Bounded process execution. */
#define _DARWIN_C_SOURCE 1

extern char **environ;

static char *copy_text(const unsigned char *bytes, size_t length) {
    if (!bytes || !length || memchr(bytes, 0, length) || length == SIZE_MAX) return NULL;
    char *text = hao_alloc(length + 1);
    if (!text) return NULL;
    memcpy(text, bytes, length);
    text[length] = 0;
    return text;
}

static void free_argv(char **argv, size_t count) {
    if (!argv) return;
    for (size_t i = 0; i <= count; ++i) hao_free(argv[i]);
    hao_free(argv);
}

static int capture_pipes(int out_fd, int err_fd, unsigned char *out, unsigned char *err,
                         size_t capacity, HaoRunResult *result, pid_t pid) {
    struct pollfd fds[2] = {
        { .fd = out_fd, .events = POLLIN },
        { .fd = err_fd, .events = POLLIN },
    };
    unsigned char *buffers[2] = { out, err };
    size_t lengths[2] = { 0, 0 };
    int open_count = 2;
    int failure = 0;
    while (open_count) {
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            failure = 2;
            break;
        }
        for (int i = 0; i < 2; ++i) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            unsigned char chunk[8192];
            ssize_t count = read(fds[i].fd, chunk, sizeof(chunk));
            if (count < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                failure = 2;
                break;
            }
            if (count == 0) {
                close(fds[i].fd);
                fds[i].fd = -1;
                --open_count;
                continue;
            }
            if ((size_t)count > capacity - lengths[i]) {
                failure = 3;
                break;
            }
            memcpy(buffers[i] + lengths[i], chunk, (size_t)count);
            lengths[i] += (size_t)count;
        }
        if (failure) break;
    }
    for (int i = 0; i < 2; ++i) if (fds[i].fd >= 0) close(fds[i].fd);
    if (failure) kill(pid, SIGKILL);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited < 0) return 2;
    if (failure) return failure;
    result->stdout_len = lengths[0];
    result->stderr_len = lengths[1];
    result->has_exit_code = WIFEXITED(status);
    result->exit_code = result->has_exit_code ? WEXITSTATUS(status) : 0;
    result->has_signal = WIFSIGNALED(status);
    result->signal = result->has_signal ? WTERMSIG(status) : 0;
    return 0;
}

int hao_process_execute(const unsigned char *program, size_t program_len,
                        const unsigned char *args, size_t args_len, size_t args_count,
                        const unsigned char *cwd, size_t cwd_len,
                        unsigned char *stdout_output, unsigned char *stderr_output,
                        size_t capacity, HaoRunResult *result) {
    if (!program || !stdout_output || !stderr_output || !result || !capacity ||
        args_count > 65536 || (args_len && !args)) return 1;
    char *command = copy_text(program, program_len);
    if (!command) return 1;
    char *directory = NULL;
    if (cwd_len) {
        directory = copy_text(cwd, cwd_len);
        if (!directory) { hao_free(command); return 1; }
    }
    char **argv = hao_calloc(args_count + 2, sizeof(char *));
    if (!argv) { hao_free(command); hao_free(directory); return 2; }
    argv[0] = command;
    size_t offset = 0;
    for (size_t i = 0; i < args_count; ++i) {
        if (offset >= args_len) { free_argv(argv, args_count); hao_free(directory); return 1; }
        const unsigned char *end = memchr(args + offset, 0, args_len - offset);
        if (!end) { free_argv(argv, args_count); hao_free(directory); return 1; }
        size_t length = (size_t)(end - args - offset);
        argv[i + 1] = hao_alloc(length + 1);
        if (!argv[i + 1]) { free_argv(argv, args_count); hao_free(directory); return 2; }
        memcpy(argv[i + 1], args + offset, length);
        argv[i + 1][length] = 0;
        offset += length + 1;
    }
    if (offset != args_len) { free_argv(argv, args_count); hao_free(directory); return 1; }
    int out_pipe[2] = { -1, -1 }, err_pipe[2] = { -1, -1 };
    if (pipe(out_pipe) || pipe(err_pipe)) {
        if (out_pipe[0] >= 0) close(out_pipe[0]);
        if (out_pipe[1] >= 0) close(out_pipe[1]);
        if (err_pipe[0] >= 0) close(err_pipe[0]);
        if (err_pipe[1] >= 0) close(err_pipe[1]);
        free_argv(argv, args_count); hao_free(directory); return 2;
    }
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    int actions_initialized = rc == 0;
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, out_pipe[0]);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, err_pipe[0]);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, out_pipe[1]);
    if (!rc) rc = posix_spawn_file_actions_addclose(&actions, err_pipe[1]);
    if (!rc && directory) rc = posix_spawn_file_actions_addchdir_np(&actions, directory);
    pid_t pid = 0;
    if (!rc) rc = posix_spawnp(&pid, command, &actions, NULL, argv, environ);
    if (actions_initialized) posix_spawn_file_actions_destroy(&actions);
    close(out_pipe[1]); close(err_pipe[1]);
    free_argv(argv, args_count); hao_free(directory);
    if (rc) { close(out_pipe[0]); close(err_pipe[0]); return 2; }
    return capture_pipes(out_pipe[0], err_pipe[0], stdout_output, stderr_output,
                         capacity, result, pid);
}
