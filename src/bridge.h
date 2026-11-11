#ifndef HAO_BRIDGE_H
#define HAO_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

uintptr_t hao_runtime_new(size_t stack_size, size_t gc_threshold, size_t thread_pool_size,
                          size_t trace_records, int console_enabled);
void hao_runtime_free(uintptr_t handle);
int hao_runtime_start_tests(uintptr_t handle, const char *grep, size_t grep_len);
int hao_runtime_test_failures(uintptr_t handle);
int hao_runtime_set_test_file_counts(uintptr_t handle, size_t loaded, size_t failed, size_t total);
int hao_runtime_set_executable(uintptr_t handle, const char *path, size_t path_len);
char *hao_runtime_eval_cell(uintptr_t handle, const char *source, size_t source_len, const char *filename, size_t filename_len);
void hao_runtime_free_text(const char *text);
int hao_runtime_drain_test(uintptr_t handle, const char *path, size_t length);
void hao_runtime_set_telemetry_console(uintptr_t handle, int enabled, uint16_t port);
void hao_runtime_set_native_stack_trace(uintptr_t handle, int enabled);
int hao_runtime_eval(uintptr_t handle, const char *source, size_t source_len, const char *filename, size_t filename_len);
int hao_runtime_eval_test(uintptr_t handle, const char *source, size_t source_len, const char *filename, size_t filename_len);
int hao_runtime_drain(uintptr_t handle);
int hao_runtime_run_turn(uintptr_t handle);
int hao_embed_bytes_valid(const unsigned char *pointer, size_t length);
void hao_embed_clear_error(uintptr_t handle);
void hao_embed_invalid_buffer(uintptr_t handle);
void hao_embed_set_error(uintptr_t handle, const unsigned char *message, size_t length);

#endif
