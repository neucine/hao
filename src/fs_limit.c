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
