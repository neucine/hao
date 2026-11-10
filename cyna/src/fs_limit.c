#include <limits.h>
#include <stdint.h>
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
