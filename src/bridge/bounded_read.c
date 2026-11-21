#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int hao_map_read_errno(int error) {
    if (error == ENOENT) return 1;
    if (error == EACCES || error == EPERM) return 2;
    if (error == EINVAL || error == ENAMETOOLONG) return 4;
    return 5;
}

static FILE *hao_open_bounded(const unsigned char *path, size_t path_len,
                              size_t max_bytes, long long *size_result) {
    if (path == NULL || path_len == SIZE_MAX || size_result == NULL) {
        if (size_result != NULL) *size_result = -4;
        return NULL;
    }
    char *path_buf = malloc(path_len + 1);
    if (path_buf == NULL) {
        *size_result = -5;
        return NULL;
    }
    memcpy(path_buf, path, path_len);
    path_buf[path_len] = 0;
    FILE *file = fopen(path_buf, "rb");
    free(path_buf);
    if (file == NULL) {
        *size_result = -hao_map_read_errno(errno);
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        *size_result = -5;
        return NULL;
    }
    long size_long = ftell(file);
    if (size_long < 0) {
        fclose(file);
        *size_result = -5;
        return NULL;
    }
    if ((uint64_t)size_long > (uint64_t)max_bytes) {
        fclose(file);
        *size_result = -3;
        return NULL;
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        *size_result = -5;
        return NULL;
    }
    *size_result = (long long)size_long;
    return file;
}

long long hao_bounded_read_length(const unsigned char *path, size_t path_len,
                                  size_t max_bytes) {
    long long size = 0;
    FILE *file = hao_open_bounded(path, path_len, max_bytes, &size);
    if (file == NULL) return size;
    if (fclose(file) != 0) return -5;
    return size;
}

int hao_bounded_read_into(const unsigned char *path, size_t path_len,
                          unsigned char *output, size_t size, int exact) {
    long long expected_size = 0;
    FILE *file = hao_open_bounded(path, path_len, size, &expected_size);
    if (file == NULL) return -expected_size;
    if ((unsigned long long)expected_size != (unsigned long long)size ||
        (size != 0 && output == NULL)) {
        fclose(file);
        return 5;
    }
    if (size != 0 && fread(output, 1, size, file) != size) {
        fclose(file);
        return 5;
    }
    if (exact && (fgetc(file) != EOF || ferror(file))) {
        fclose(file);
        return 5;
    }
    if (fclose(file) != 0) return 5;

    return 0;
}
