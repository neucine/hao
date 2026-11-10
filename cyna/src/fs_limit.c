#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

int hao_fs_within_limit(const unsigned char *path, size_t length, size_t limit) {
    if (!path || length > PATH_MAX) return 0;
    char buffer[PATH_MAX + 1];
    memcpy(buffer, path, length);
    buffer[length] = 0;
    struct stat info;
    return stat(buffer, &info) == 0 && info.st_size >= 0 && (uintmax_t)info.st_size <= limit;
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
