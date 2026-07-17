#ifndef HAO_H
#define HAO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HAO_NATIVE_ABI_VERSION 1

typedef uintptr_t HaoValue;

typedef struct HaoNativeContext HaoNativeContext;
typedef struct HaoNativeRegistry HaoNativeRegistry;

typedef HaoValue (*HaoNativeFunctionCallback)(
    HaoNativeContext* ctx,
    int argc,
    const HaoValue* argv
);

typedef struct HaoNativeFunction {
    const char* name;
    HaoNativeFunctionCallback callback;
    int length;
} HaoNativeFunction;

typedef struct HaoNativeModule {
    const char* specifier;
    const HaoNativeFunction* functions;
} HaoNativeModule;

typedef struct HaoNativeRegistryApi {
    uint32_t abi_version;
    int (*add_module)(HaoNativeRegistry* registry, const HaoNativeModule* module);
} HaoNativeRegistryApi;

struct HaoNativeRegistry {
    const HaoNativeRegistryApi* api;
    void* data;
};

typedef struct HaoNativeContextApi {
    uint32_t abi_version;
    HaoValue (*undefined)(HaoNativeContext* ctx);
    HaoValue (*null_value)(HaoNativeContext* ctx);
    HaoValue (*bool_value)(HaoNativeContext* ctx, int value);
    HaoValue (*int32_value)(HaoNativeContext* ctx, int32_t value);
    HaoValue (*float64_value)(HaoNativeContext* ctx, double value);
    HaoValue (*string_value)(HaoNativeContext* ctx, const char* value);
    int (*to_bool)(HaoNativeContext* ctx, HaoValue value, int* out);
    int (*to_int32)(HaoNativeContext* ctx, HaoValue value, int32_t* out);
    int (*to_float64)(HaoNativeContext* ctx, HaoValue value, double* out);
    const char* (*to_string)(HaoNativeContext* ctx, HaoValue value);
    HaoValue (*throw_type_error)(HaoNativeContext* ctx, const char* message);
    HaoValue (*throw_error)(HaoNativeContext* ctx, const char* message);
} HaoNativeContextApi;

struct HaoNativeContext {
    const HaoNativeContextApi* api;
    void* data;
};

typedef int (*HaoRegisterModulesFn)(HaoNativeRegistry* registry);

static inline int hao_native_add_module(
    HaoNativeRegistry* registry,
    const HaoNativeModule* module
) {
    return registry->api->add_module(registry, module);
}

static inline HaoValue hao_undefined(HaoNativeContext* ctx) {
    return ctx->api->undefined(ctx);
}

static inline HaoValue hao_null(HaoNativeContext* ctx) {
    return ctx->api->null_value(ctx);
}

static inline HaoValue hao_bool(HaoNativeContext* ctx, int value) {
    return ctx->api->bool_value(ctx, value);
}

static inline HaoValue hao_int32(HaoNativeContext* ctx, int32_t value) {
    return ctx->api->int32_value(ctx, value);
}

static inline HaoValue hao_float64(HaoNativeContext* ctx, double value) {
    return ctx->api->float64_value(ctx, value);
}

static inline HaoValue hao_string(HaoNativeContext* ctx, const char* value) {
    return ctx->api->string_value(ctx, value);
}

static inline int hao_to_bool(HaoNativeContext* ctx, HaoValue value, int* out) {
    return ctx->api->to_bool(ctx, value, out);
}

static inline int hao_to_int32(HaoNativeContext* ctx, HaoValue value, int32_t* out) {
    return ctx->api->to_int32(ctx, value, out);
}

static inline int hao_to_float64(HaoNativeContext* ctx, HaoValue value, double* out) {
    return ctx->api->to_float64(ctx, value, out);
}

static inline const char* hao_to_string(HaoNativeContext* ctx, HaoValue value) {
    return ctx->api->to_string(ctx, value);
}

static inline HaoValue hao_throw_type_error(HaoNativeContext* ctx, const char* message) {
    return ctx->api->throw_type_error(ctx, message);
}

static inline HaoValue hao_throw_error(HaoNativeContext* ctx, const char* message) {
    return ctx->api->throw_error(ctx, message);
}

#ifdef __cplusplus
}
#endif

#endif
