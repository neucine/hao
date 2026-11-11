#include "native.h"
#include <quickjs.h>
#include "../../runtime_allocator.h"
#include "../../cyna_exports.h"
#include "../../fs_limit.h"
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static JSValue hao_fs_arg_error(JSContext *ctx, const char *message) {
    JSValue cause = JS_GetException(ctx);
    JS_FreeValue(ctx, cause);
    return JS_ThrowTypeError(ctx, "%s", message);
}

static JSValue hao_fs_exists_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "existsSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "existsSync expects a path");
    int found = hao_fs_exists((const unsigned char *)path);
    JS_FreeCString(ctx, path);
    return JS_NewBool(ctx, found != 0);
}

static JSValue hao_fs_read_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "readFileSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "readFileSync expects a path");
    unsigned char *buffer = hao_fs_read_alloc_limited((const unsigned char *)path,
                                                      strlen(path), 100 * 1024 * 1024);
    JS_FreeCString(ctx, path);
    if (!buffer) return JS_ThrowInternalError(ctx, "failed to read file");
    JSValue result = JS_NewString(ctx, (const char *)buffer);
    hao_fs_free_buffer(buffer);
    return result;
}

static JSValue hao_fs_write_file_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "writeFileSync expects a path");
    if (argc < 2) return JS_ThrowTypeError(ctx, "writeFileSync expects data");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "writeFileSync expects a path");
    size_t length = 0;
    const char *data = JS_ToCStringLen(ctx, &length, argv[1]);
    if (!data) {
        JS_FreeCString(ctx, path);
        return hao_fs_arg_error(ctx, "writeFileSync expects data");
    }
    int status = hao_fs_write((const unsigned char *)path, (const unsigned char *)data, strlen(data));
    JS_FreeCString(ctx, data);
    JS_FreeCString(ctx, path);
    if (status != 0) return JS_ThrowInternalError(ctx, "failed to write file");
    return JS_UNDEFINED;
}

static JSValue hao_fs_stat_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_ThrowTypeError(ctx, "statSync expects a path");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return hao_fs_arg_error(ctx, "statSync expects a path");
    FILE *file = fopen(path, "rb");
    JS_FreeCString(ctx, path);
    if (!file) return JS_ThrowInternalError(ctx, "failed to stat file");
    int status = fseek(file, 0, SEEK_END);
    long size = status == 0 ? ftell(file) : -1;
    fclose(file);
    if (size < 0) return JS_ThrowInternalError(ctx, "failed to stat file");
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    JS_SetPropertyStr(ctx, result, "size", JS_NewFloat64(ctx, (double)size));
    return result;
}

void hao_install_fs_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_fs_existsSync", JS_NewCFunction(ctx, hao_fs_exists_sync, "existsSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_readFileSync", JS_NewCFunction(ctx, hao_fs_read_file_sync, "readFileSync", 1));
    JS_SetPropertyStr(ctx, global, "__hao_fs_writeFileSync", JS_NewCFunction(ctx, hao_fs_write_file_sync, "writeFileSync", 2));
    JS_SetPropertyStr(ctx, global, "__hao_fs_statSync", JS_NewCFunction(ctx, hao_fs_stat_sync, "statSync", 1));
}
