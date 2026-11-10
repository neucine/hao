#include <quickjs.h>
#include "../../runtime_allocator.h"
#include <ffi/ffi.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    HAO_VOID, HAO_BOOL, HAO_I8, HAO_I16, HAO_I32, HAO_I64,
    HAO_U8, HAO_U16, HAO_U32, HAO_U64, HAO_F32, HAO_F64,
    HAO_PTR, HAO_CSTRING, HAO_BUFFER
} HaoType;

typedef struct HaoBinding {
    char *name;
    void *function;
    size_t arg_count;
    HaoType args[8];
    HaoType returns;
    ffi_type *arg_ffi[8];
    ffi_cif cif;
    struct HaoBinding *next;
} HaoBinding;

typedef struct HaoLibrary {
    int64_t id;
    JSContext *ctx;
    void *library;
    bool closed;
    HaoBinding *bindings;
    struct HaoLibrary *next;
} HaoLibrary;

static HaoLibrary *libraries;
static int64_t next_id = 1;

static HaoLibrary *find_library(JSContext *ctx, int64_t id) {
    for (HaoLibrary *library = libraries; library; library = library->next)
        if (library->id == id && library->ctx == ctx) return library;
    return NULL;
}
static HaoBinding *find_binding(HaoLibrary *library, const char *name) {
    for (HaoBinding *binding = library->bindings; binding; binding = binding->next)
        if (strcmp(binding->name, name) == 0) return binding;
    return NULL;
}
static void free_bindings(HaoLibrary *library) {
    HaoBinding *binding = library->bindings;
    library->bindings = NULL;
    while (binding) {
        HaoBinding *next = binding->next;
        hao_free(binding->name);
        hao_free(binding);
        binding = next;
    }
}
static void free_library(HaoLibrary *library) {
    free_bindings(library);
    if (library->library) dlclose(library->library);
    hao_free(library);
}
static void close_library(HaoLibrary *library) {
    if (library->closed) return;
    library->closed = true;
    dlclose(library->library);
    library->library = NULL;
    free_bindings(library);
}
void hao_ffi_cleanup(JSContext *ctx) {
    HaoLibrary **link = &libraries;
    while (*link) {
        HaoLibrary *library = *link;
        if (library->ctx == ctx) {
            *link = library->next;
            free_library(library);
        } else {
            link = &library->next;
        }
    }
}
static bool parse_type(const char *name, HaoType *out) {
    static const char *names[] = { "void", "bool", "i8", "i16", "i32", "i64",
        "u8", "u16", "u32", "u64", "f32", "f64", "ptr", "cstring", "buffer" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(name, names[i]) == 0) { *out = (HaoType)i; return true; }
    }
    return false;
}
static ffi_type *ffi_type_for(HaoType type) {
    switch (type) {
        case HAO_VOID: return &ffi_type_void;
        case HAO_BOOL: case HAO_U8: return &ffi_type_uint8;
        case HAO_I8: return &ffi_type_sint8;
        case HAO_I16: return &ffi_type_sint16;
        case HAO_U16: return &ffi_type_uint16;
        case HAO_I32: return &ffi_type_sint32;
        case HAO_U32: return &ffi_type_uint32;
        case HAO_I64: return &ffi_type_sint64;
        case HAO_U64: return &ffi_type_uint64;
        case HAO_F32: return &ffi_type_float;
        case HAO_F64: return &ffi_type_double;
        case HAO_PTR: case HAO_CSTRING: case HAO_BUFFER: return &ffi_type_pointer;
    }
    return NULL;
}
static JSValue open_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsString(argv[0])) return JS_ThrowTypeError(ctx, "dlopen: invalid library name");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_EXCEPTION;
    size_t length = strlen(name);
    if (!length || length > 4096) { JS_FreeCString(ctx, name); return JS_ThrowTypeError(ctx, "dlopen: invalid library name"); }
    char *path = NULL;
    if (!strchr(name, '/') && !strchr(name, '.')) {
        path = hao_alloc(length + 10);
        if (!path) { JS_FreeCString(ctx, name); return JS_ThrowOutOfMemory(ctx); }
#if defined(__APPLE__)
        snprintf(path, length + 10, "lib%s.dylib", name);
#else
        snprintf(path, length + 10, "lib%s.so", name);
#endif
    }
    void *handle = dlopen(path ? path : name, RTLD_NOW | RTLD_LOCAL);
    hao_free(path);
    JS_FreeCString(ctx, name);
    if (!handle) return JS_ThrowInternalError(ctx, "dlopen: failed to open library");
    HaoLibrary *library = hao_calloc(1, sizeof(*library));
    if (!library) { dlclose(handle); return JS_ThrowOutOfMemory(ctx); }
    library->id = next_id++;
    library->ctx = ctx;
    library->library = handle;
    library->next = libraries;
    libraries = library;
    return JS_NewInt64(ctx, library->id);
}
static JSValue bind_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 4 || JS_ToInt64(ctx, &id, argv[0]) != 0 || !JS_IsString(argv[1]) || !JS_IsArray(argv[2]) || !JS_IsString(argv[3]))
        return JS_ThrowTypeError(ctx, "FFI: invalid binding descriptor");
    HaoLibrary *library = find_library(ctx, id);
    if (!library) return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    if (library->closed) return JS_ThrowTypeError(ctx, "FFI: library has been closed");
    const char *name = JS_ToCString(ctx, argv[1]);
    const char *return_name = JS_ToCString(ctx, argv[3]);
    if (!name || !return_name) {
        if (name) JS_FreeCString(ctx, name);
        if (return_name) JS_FreeCString(ctx, return_name);
        return JS_EXCEPTION;
    }
    HaoBinding *binding = hao_calloc(1, sizeof(*binding));
    if (!binding) { JS_FreeCString(ctx, name); JS_FreeCString(ctx, return_name); return JS_ThrowOutOfMemory(ctx); }
    JSValue count_value = JS_GetPropertyStr(ctx, argv[2], "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    bool valid = count <= 8 && parse_type(return_name, &binding->returns) && !find_binding(library, name);
    binding->arg_count = count;
    for (uint32_t i = 0; valid && i < count; i++) {
        JSValue value = JS_GetPropertyUint32(ctx, argv[2], i);
        const char *type_name = JS_ToCString(ctx, value);
        valid = type_name && parse_type(type_name, &binding->args[i]) && binding->args[i] != HAO_VOID;
        if (valid) binding->arg_ffi[i] = ffi_type_for(binding->args[i]);
        if (type_name) JS_FreeCString(ctx, type_name);
        JS_FreeValue(ctx, value);
    }
    if (valid) binding->function = dlsym(library->library, name);
    bool missing_symbol = valid && binding->function == NULL;
    if (missing_symbol) valid = false;
    if (valid) valid = ffi_prep_cif(&binding->cif, FFI_DEFAULT_ABI, count,
        ffi_type_for(binding->returns), binding->arg_ffi) == FFI_OK;
    if (valid) binding->name = hao_strdup(name);
    valid = valid && binding->name;
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, return_name);
    if (!valid) {
        hao_free(binding);
        if (missing_symbol) return JS_ThrowInternalError(ctx, "dlopen: symbol not found");
        return JS_ThrowTypeError(ctx, "dlopen: invalid descriptor");
    }
    binding->next = library->bindings;
    library->bindings = binding;
    return JS_UNDEFINED;
}

typedef union {
    int8_t i8; int16_t i16; int32_t i32; int64_t i64;
    uint8_t u8; uint16_t u16; uint32_t u32; uint64_t u64;
    float f32; double f64; void *ptr;
} HaoValue;

static JSValue result_value(JSContext *ctx, HaoType type, HaoValue value) {
    switch (type) {
        case HAO_VOID: return JS_UNDEFINED;
        case HAO_BOOL: return JS_NewBool(ctx, value.u8 != 0);
        case HAO_I8: return JS_NewInt32(ctx, value.i8);
        case HAO_I16: return JS_NewInt32(ctx, value.i16);
        case HAO_I32: return JS_NewInt32(ctx, value.i32);
        case HAO_I64: return JS_NewInt64(ctx, value.i64);
        case HAO_U8: return JS_NewInt32(ctx, value.u8);
        case HAO_U16: return JS_NewInt32(ctx, value.u16);
        case HAO_U32: return JS_NewInt64(ctx, value.u32);
        case HAO_U64: return JS_NewFloat64(ctx, (double)value.u64);
        case HAO_F32: return JS_NewFloat64(ctx, value.f32);
        case HAO_F64: return JS_NewFloat64(ctx, value.f64);
        case HAO_PTR: case HAO_BUFFER: return JS_NewInt64(ctx, (int64_t)(uintptr_t)value.ptr);
        case HAO_CSTRING: {
            if (!value.ptr) return JS_NULL;
            const char *text = value.ptr;
            return JS_NewStringLen(ctx, text, strnlen(text, 1024 * 1024));
        }
    }
    return JS_UNDEFINED;
}

static bool unsigned_arg(JSContext *ctx, JSValueConst input, uint64_t *out) {
    int64_t signed_value = 0;
    if (JS_ToInt64(ctx, &signed_value, input) == 0) {
        if (signed_value < 0) return false;
        *out = (uint64_t)signed_value;
        return true;
    }
    JSValue error = JS_GetException(ctx);
    JS_FreeValue(ctx, error);
    if (!JS_IsBigInt(input)) return false;
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, input);
    if (!text) return false;
    while (length && text[length - 1] == 'n') length--;
    uint64_t parsed = 0;
    bool valid = length > 0;
    for (size_t i = 0; valid && i < length; i++) {
        unsigned digit = (unsigned char)text[i] - '0';
        if (digit > 9 || parsed > (UINT64_MAX - digit) / 10) valid = false;
        else parsed = parsed * 10 + digit;
    }
    JS_FreeCString(ctx, text);
    if (valid) *out = parsed;
    return valid;
}
static JSValue call_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 3 || JS_ToInt64(ctx, &id, argv[0]) != 0 || !JS_IsString(argv[1]) || !JS_IsArray(argv[2]))
        return JS_ThrowTypeError(ctx, "FFI: invalid call arguments");
    HaoLibrary *library = find_library(ctx, id);
    if (!library) return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    if (library->closed) return JS_ThrowTypeError(ctx, "FFI: library has been closed");
    const char *name = JS_ToCString(ctx, argv[1]);
    if (!name) return JS_EXCEPTION;
    HaoBinding *binding = find_binding(library, name);
    JS_FreeCString(ctx, name);
    if (!binding) return JS_ThrowTypeError(ctx, "FFI: unknown symbol");
    JSValue count_value = JS_GetPropertyStr(ctx, argv[2], "length");
    uint32_t count = 0;
    JS_ToUint32(ctx, &count, count_value);
    JS_FreeValue(ctx, count_value);
    if (count != binding->arg_count) return JS_ThrowTypeError(ctx, "FFI: wrong number of arguments");
    int32_t out_index = -1;
    if (argc >= 4 && !JS_IsUndefined(argv[3])) {
        if (JS_ToInt32(ctx, &out_index, argv[3]) < 0 || out_index < 0 || (uint32_t)out_index >= count ||
            binding->args[out_index] != HAO_PTR)
            return JS_ThrowTypeError(ctx, "FFI: invalid output parameter");
    }
    HaoValue values[8] = {0};
    uintptr_t out_pointer = 0;
    void *pointers[8] = {0};
    JSValue held_buffers[8];
    const char *held_strings[8] = {0};
    size_t held_count = 0;
    bool valid = true;
    for (uint32_t i = 0; i < count; i++) {
        JSValue input = JS_GetPropertyUint32(ctx, argv[2], i);
        held_buffers[i] = JS_UNDEFINED;
        pointers[i] = &values[i];
        HaoType type = binding->args[i];
        if ((int32_t)i == out_index) {
            values[i].ptr = &out_pointer;
        } else if (type == HAO_F32 || type == HAO_F64) {
            double number = 0;
            valid = JS_ToFloat64(ctx, &number, input) == 0;
            values[i].f32 = (float)number;
            if (type == HAO_F64) values[i].f64 = number;
        } else if (type == HAO_CSTRING) {
            held_strings[i] = JS_ToCString(ctx, input);
            valid = held_strings[i] != NULL;
            values[i].ptr = (void *)held_strings[i];
        } else if ((type == HAO_PTR || type == HAO_BUFFER) && JS_IsObject(input)) {
            size_t offset = 0, length = 0, total = 0;
            held_buffers[i] = JS_GetTypedArrayBuffer(ctx, input, &offset, &length, NULL);
            if (!JS_IsException(held_buffers[i])) {
                uint8_t *bytes = JS_GetArrayBuffer(ctx, &total, held_buffers[i]);
                valid = bytes && offset <= total && length <= total - offset;
                if (valid) values[i].ptr = bytes + offset;
            } else valid = false;
        } else if (type == HAO_BOOL) {
            int boolean = JS_ToBool(ctx, input);
            valid = boolean >= 0;
            values[i].u8 = boolean > 0;
        } else if (type == HAO_U8 || type == HAO_U16 || type == HAO_U32 || type == HAO_U64 || type == HAO_PTR || type == HAO_BUFFER) {
            uint64_t number = 0;
            valid = unsigned_arg(ctx, input, &number);
            values[i].u64 = number;
            if (type == HAO_U8) values[i].u8 = (uint8_t)number;
            if (type == HAO_U16) values[i].u16 = (uint16_t)number;
            if (type == HAO_U32) values[i].u32 = (uint32_t)number;
            if (type == HAO_PTR || type == HAO_BUFFER) values[i].ptr = (void *)(uintptr_t)number;
        } else {
            int64_t number = 0;
            valid = JS_ToInt64(ctx, &number, input) == 0;
            values[i].i64 = number;
            if (type == HAO_I8) values[i].i8 = (int8_t)number;
            if (type == HAO_I16) values[i].i16 = (int16_t)number;
            if (type == HAO_I32) values[i].i32 = (int32_t)number;
        }
        JS_FreeValue(ctx, input);
        held_count++;
        if (!valid) break;
    }
    JSValue result;
    if (valid) {
        HaoValue returned = {0};
        ffi_call(&binding->cif, FFI_FN(binding->function), &returned, pointers);
        result = result_value(ctx, binding->returns, returned);
        if (out_index >= 0 && !JS_IsException(result)) {
            JSValue pair = JS_NewObject(ctx);
            JS_SetPropertyStr(ctx, pair, "raw", result);
            JS_SetPropertyStr(ctx, pair, "out", JS_NewInt64(ctx, (int64_t)out_pointer));
            result = pair;
        }
    } else result = JS_ThrowTypeError(ctx, "FFI: invalid argument value");
    for (size_t i = 0; i < held_count; i++) {
        if (held_strings[i]) JS_FreeCString(ctx, held_strings[i]);
        JS_FreeValue(ctx, held_buffers[i]);
    }
    return result;
}
static JSValue close_native(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int64_t id = 0;
    if (argc < 1) return JS_ThrowTypeError(ctx, "ffi.closeNative requires a handle");
    if (JS_ToInt64(ctx, &id, argv[0]) < 0 || id <= 0)
        return JS_ThrowTypeError(ctx, "FFI: invalid library handle");
    HaoLibrary *library = find_library(ctx, id);
    if (library) close_library(library);
    return JS_UNDEFINED;
}
void hao_install_ffi_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_ffi_open", JS_NewCFunction(ctx, open_native, "open", 1));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_bind", JS_NewCFunction(ctx, bind_native, "bind", 4));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_call", JS_NewCFunction(ctx, call_native, "call", 3));
    JS_SetPropertyStr(ctx, global, "__hao_ffi_close", JS_NewCFunction(ctx, close_native, "close", 1));
}
