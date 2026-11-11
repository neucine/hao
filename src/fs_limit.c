#include "fs_limit.h"
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

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
