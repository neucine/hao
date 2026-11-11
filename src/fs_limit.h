#ifndef HAO_FS_LIMIT_H
#define HAO_FS_LIMIT_H

#include <stddef.h>
#include <stdint.h>

int hao_fs_read_limited(const unsigned char *path, size_t length, unsigned char *output, size_t capacity);
int hao_fs_script_read_error(const unsigned char *path, size_t length, size_t limit);
unsigned char *hao_fs_read_alloc_limited(const unsigned char *path, size_t length, size_t limit);
size_t hao_fs_buffer_length(const unsigned char *buffer);
void hao_fs_free_buffer(unsigned char *buffer);
int hao_fs_path_exists(const unsigned char *path);
int hao_fs_path_exists_len(const unsigned char *path, size_t length);

#endif
