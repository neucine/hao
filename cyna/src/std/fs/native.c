#include <quickjs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

extern int hao_fs_exists(const unsigned char *path);
extern int hao_fs_read_into(const unsigned char *path, unsigned char *output, size_t capacity);
extern int hao_fs_write(const unsigned char *path, const unsigned char *data, size_t length);

unsigned char hao_byte_at(const unsigned char *pointer, size_t index) {
    return pointer[index];
}

void hao_copy_bytes(unsigned char *output, const unsigned char *input, size_t length) {
    memcpy(output, input, length);
}

static JSValue hao_fs_exists_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "existsSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    int found = hao_fs_exists((const unsigned char *)path);
    JS_FreeCString(ctx, path);
    return JS_NewBool(ctx, found != 0);
}

static JSValue hao_fs_read_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "readFileSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    struct stat info;
    if (stat(path, &info) != 0 || info.st_size < 0 || info.st_size > 100 * 1024 * 1024) {
        JS_FreeCString(ctx, path);
        return JS_ThrowInternalError(ctx, "failed to read file");
    }
    size_t capacity = (size_t)info.st_size;
    unsigned char *buffer = malloc(capacity ? capacity : 1);
    if (!buffer) {
        JS_FreeCString(ctx, path);
        return JS_ThrowOutOfMemory(ctx);
    }
    int length = hao_fs_read_into((const unsigned char *)path, buffer, capacity);
    JS_FreeCString(ctx, path);
    if (length < 0) {
        free(buffer);
        return JS_ThrowInternalError(ctx, "failed to read file");
    }
    JSValue result = JS_NewStringLen(ctx, (const char *)buffer, (size_t)length);
    free(buffer);
    return result;
}

static JSValue hao_fs_write_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_ThrowTypeError(ctx, "writeFileSync expects path and data");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    size_t length = 0;
    const char *data = JS_ToCStringLen(ctx, &length, argv[1]);
    if (!data) {
        JS_FreeCString(ctx, path);
        return JS_EXCEPTION;
    }
    int status = hao_fs_write((const unsigned char *)path, (const unsigned char *)data, length);
    JS_FreeCString(ctx, data);
    JS_FreeCString(ctx, path);
    if (status != 0) return JS_ThrowInternalError(ctx, "failed to write file");
    return JS_UNDEFINED;
}

static JSValue hao_fs_stat_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "statSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    struct stat info;
    int status = stat(path, &info);
    JS_FreeCString(ctx, path);
    if (status != 0) return JS_ThrowInternalError(ctx, "failed to stat file");
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    JS_SetPropertyStr(ctx, result, "size", JS_NewFloat64(ctx, (double)info.st_size));
    return result;
}

void hao_install_fs_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_fs_existsSync", JS_NewCFunction(ctx, hao_fs_exists_sync, "existsSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_readFileSync", JS_NewCFunction(ctx, hao_fs_read_file_sync, "readFileSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_writeFileSync", JS_NewCFunction(ctx, hao_fs_write_file_sync, "writeFileSync", 2));
    JS_SetPropertyStr(ctx, global, "__hao_fs_statSync", JS_NewCFunction(ctx, hao_fs_stat_sync, "statSync", 1));
}
