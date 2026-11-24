#define _DARWIN_C_SOURCE 1
#include "host.h"

#include "allocator.h"

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
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

#if !defined(_WIN32)
extern char **environ;
#endif

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

#if defined(_WIN32)
typedef struct {
    HANDLE process;
    HANDLE pipes[2];
    unsigned char *outputs[2];
    size_t capacity;
    size_t lengths[2];
    volatile LONG failure;
} HaoWindowsCapture;

typedef struct {
    HaoWindowsCapture *capture;
    int index;
} HaoWindowsReader;

static DWORD WINAPI read_capture_pipe(LPVOID opaque) {
    HaoWindowsReader *reader = opaque;
    HaoWindowsCapture *capture = reader->capture;
    int index = reader->index;
    unsigned char chunk[8192];
    DWORD count = 0;
    while (ReadFile(capture->pipes[index], chunk, sizeof(chunk), &count, NULL) && count) {
        if ((size_t)count > capture->capacity - capture->lengths[index]) {
            InterlockedExchange(&capture->failure, 3);
            TerminateProcess(capture->process, 1);
            break;
        }
        memcpy(capture->outputs[index] + capture->lengths[index], chunk, (size_t)count);
        capture->lengths[index] += (size_t)count;
    }
    DWORD error = GetLastError();
    if (error != ERROR_BROKEN_PIPE && error != ERROR_HANDLE_EOF && error != ERROR_SUCCESS &&
        InterlockedCompareExchange(&capture->failure, 2, 0) == 0) {
        capture->failure = 2;
    }
    CloseHandle(capture->pipes[index]);
    capture->pipes[index] = NULL;
    return 0;
}

static size_t windows_quoted_length(const char *text) {
    size_t length = strlen(text);
    if (length > (SIZE_MAX - 3) / 2) return SIZE_MAX;
    return length * 2 + 3;
}

static bool windows_arg_needs_quotes(const char *text) {
    return text[0] == 0 || strpbrk(text, " \t\n\v\f\r\"") != NULL;
}

static char *append_windows_arg(char *output, const char *text) {
    if (!windows_arg_needs_quotes(text)) {
        size_t length = strlen(text);
        memcpy(output, text, length);
        return output + length;
    }
    *output++ = '"';
    size_t backslashes = 0;
    for (const char *cursor = text;; cursor++) {
        if (*cursor == '\\') {
            backslashes++;
            continue;
        }
        if (*cursor == '"') {
            for (size_t i = 0; i < backslashes * 2 + 1; i++) *output++ = '\\';
            *output++ = '"';
            backslashes = 0;
            continue;
        }
        if (*cursor == 0) {
            for (size_t i = 0; i < backslashes * 2; i++) *output++ = '\\';
            backslashes = 0;
            break;
        }
        for (size_t i = 0; i < backslashes; i++) *output++ = '\\';
        backslashes = 0;
        *output++ = *cursor;
    }
    for (size_t i = 0; i < backslashes; i++) *output++ = '\\';
    *output++ = '"';
    return output;
}

static char *windows_command_line(char **argv, size_t count) {
    size_t required = 1;
    for (size_t i = 0; i <= count; i++) {
        size_t length = windows_quoted_length(argv[i]);
        if (length == SIZE_MAX || required > SIZE_MAX - length - 1) return NULL;
        required += length + (i ? 1 : 0);
    }
    char *line = hao_alloc(required);
    if (!line) return NULL;
    char *cursor = line;
    for (size_t i = 0; i <= count; i++) {
        if (i) *cursor++ = ' ';
        cursor = append_windows_arg(cursor, argv[i]);
    }
    *cursor = 0;
    return line;
}

static int capture_windows(HANDLE process, HANDLE out_read, HANDLE err_read,
                           unsigned char *out, unsigned char *err, size_t capacity,
                           HaoRunResult *result) {
    HaoWindowsCapture capture = {
        .process = process,
        .pipes = { out_read, err_read },
        .outputs = { out, err },
        .capacity = capacity,
    };
    HaoWindowsReader readers[2] = {
        { .capture = &capture, .index = 0 },
        { .capture = &capture, .index = 1 },
    };
    HANDLE threads[2] = {
        CreateThread(NULL, 0, read_capture_pipe, &readers[0], 0, NULL),
        CreateThread(NULL, 0, read_capture_pipe, &readers[1], 0, NULL),
    };
    if (!threads[0] || !threads[1]) {
        TerminateProcess(process, 1);
        if (threads[0]) WaitForSingleObject(threads[0], INFINITE);
        if (threads[1]) WaitForSingleObject(threads[1], INFINITE);
        if (threads[0]) CloseHandle(threads[0]);
        if (threads[1]) CloseHandle(threads[1]);
        if (capture.pipes[0]) CloseHandle(capture.pipes[0]);
        if (capture.pipes[1]) CloseHandle(capture.pipes[1]);
        return 2;
    }
    WaitForSingleObject(threads[0], INFINITE);
    WaitForSingleObject(threads[1], INFINITE);
    CloseHandle(threads[0]);
    CloseHandle(threads[1]);
    if (WaitForSingleObject(process, INFINITE) != WAIT_OBJECT_0) return 2;
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process, &exit_code)) return 2;
    if (capture.failure) return (int)capture.failure;
    result->stdout_len = capture.lengths[0];
    result->stderr_len = capture.lengths[1];
    result->has_exit_code = 1;
    result->exit_code = (int)exit_code;
    result->has_signal = 0;
    result->signal = 0;
    return 0;
}
#else
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
#endif

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
#if defined(_WIN32)
    char *line = windows_command_line(argv, args_count);
    if (!line) { free_argv(argv, args_count); hao_free(directory); return 2; }
    SECURITY_ATTRIBUTES security = {
        .nLength = sizeof(security),
        .lpSecurityDescriptor = NULL,
        .bInheritHandle = TRUE,
    };
    HANDLE out_read = NULL, out_write = NULL, err_read = NULL, err_write = NULL;
    HANDLE null_input = CreateFileA("NUL", GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, NULL);
    if (null_input == INVALID_HANDLE_VALUE ||
        !CreatePipe(&out_read, &out_write, &security, 0) ||
        !CreatePipe(&err_read, &err_write, &security, 0)) {
        if (null_input != INVALID_HANDLE_VALUE) CloseHandle(null_input);
        if (out_read) CloseHandle(out_read);
        if (out_write) CloseHandle(out_write);
        if (err_read) CloseHandle(err_read);
        if (err_write) CloseHandle(err_write);
        hao_free(line);
        free_argv(argv, args_count);
        hao_free(directory);
        return 2;
    }
    SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(err_read, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOA startup = {
        .cb = sizeof(startup),
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdInput = null_input,
        .hStdOutput = out_write,
        .hStdError = err_write,
    };
    PROCESS_INFORMATION child = {0};
    BOOL started = CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL,
                                  directory, &startup, &child);
    CloseHandle(null_input);
    CloseHandle(out_write);
    CloseHandle(err_write);
    hao_free(line);
    free_argv(argv, args_count);
    hao_free(directory);
    if (!started) {
        CloseHandle(out_read);
        CloseHandle(err_read);
        return 2;
    }
    CloseHandle(child.hThread);
    int status = capture_windows(child.hProcess, out_read, err_read,
                                 stdout_output, stderr_output, capacity, result);
    CloseHandle(child.hProcess);
    return status;
#else
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
#endif
}
