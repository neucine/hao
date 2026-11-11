#include "fs_limit.h"
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include "runtime_allocator.h"

int hao_fs_path_exists(const unsigned char *path) {
    return path && access((const char *)path, F_OK) == 0 ? 1 : 0;
}

int hao_fs_path_exists_len(const unsigned char *path, size_t length) {
    if (!path || length > PATH_MAX || memchr(path, 0, length)) return 0;
    char buffer[PATH_MAX + 1];
    memcpy(buffer, path, length);
    buffer[length] = 0;
    return access(buffer, F_OK) == 0 ? 1 : 0;
}

int hao_fs_script_read_error(const unsigned char *path, size_t length, size_t limit) {
    if (!path || length > PATH_MAX || memchr(path, 0, length)) return 2;
    char buffer[PATH_MAX + 1];
    memcpy(buffer, path, length);
    buffer[length] = 0;
    FILE *file = fopen(buffer, "rb");
    if (!file) return 0;
    int result = 3;
    struct stat info;
    if (fstat(fileno(file), &info) != 0 || S_ISDIR(info.st_mode)) goto done;
    if (fseek(file, 0, SEEK_END) != 0) goto done;
    long size = ftell(file);
    if (size < 0) goto done;
    result = (uintmax_t)size > limit ? 1 : 4;
done:
    fclose(file);
    return result;
}

int hao_fs_read_limited(const unsigned char *path, size_t length, unsigned char *output, size_t capacity) {
    if (!path || !output || length > PATH_MAX || capacity > INT_MAX) return -1;
    char buffer[PATH_MAX + 1];
    memcpy(buffer, path, length);
    buffer[length] = 0;
    FILE *file = fopen(buffer, "rb");
    if (!file) return -1;
    int result = -1;
    if (fseek(file, 0, SEEK_END) != 0) goto done;
    long size = ftell(file);
    if (size < 0 || (uintmax_t)size > capacity) goto done;
    if (fseek(file, 0, SEEK_SET) != 0) goto done;
    if (fread(output, 1, (size_t)size, file) != (size_t)size) goto done;
    if (fgetc(file) != EOF || ferror(file)) goto done;
    result = (int)size;
done:
    fclose(file);
    return result;
}

unsigned char *hao_fs_read_alloc_limited(const unsigned char *path, size_t length,
                                         size_t limit) {
    if (!path || length > PATH_MAX || memchr(path, 0, length)) return NULL;
    char buffer[PATH_MAX + 1];
    memcpy(buffer, path, length);
    buffer[length] = 0;
    FILE *file = fopen(buffer, "rb");
    if (!file) return NULL;
    unsigned char *storage = NULL;
    if (fseek(file, 0, SEEK_END) != 0) goto done;
    long size = ftell(file);
    if (size < 0 || (uintmax_t)size > limit || (size_t)size > SIZE_MAX - sizeof(size_t) - 1) goto done;
    if (fseek(file, 0, SEEK_SET) != 0) goto done;
    size_t content_size = (size_t)size;
    storage = hao_alloc(sizeof(size_t) + content_size + 1);
    if (!storage) goto done;
    memcpy(storage, &content_size, sizeof(size_t));
    unsigned char *content = storage + sizeof(size_t);
    if (fread(content, 1, content_size, file) != content_size) {
        hao_free(storage);
        storage = NULL;
        goto done;
    }
    content[content_size] = 0;
done:
    fclose(file);
    return storage ? storage + sizeof(size_t) : NULL;
}

size_t hao_fs_buffer_length(const unsigned char *buffer) {
    size_t length = 0;
    if (buffer) memcpy(&length, buffer - sizeof(size_t), sizeof(size_t));
    return length;
}

void hao_fs_free_buffer(unsigned char *buffer) {
    if (buffer) hao_free(buffer - sizeof(size_t));
}
