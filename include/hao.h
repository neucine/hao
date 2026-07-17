#ifndef JS_ADDON_H
#define JS_ADDON_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JS_ADDON_ABI_VERSION 1

typedef uintptr_t JsValue;

typedef struct JsContext JsContext;
typedef struct JsRegistry JsRegistry;

typedef JsValue (*JsFunctionCallback)(
    JsContext* ctx,
    int argc,
    const JsValue* argv
);

typedef struct JsFunction {
    const char* name;
    JsFunctionCallback callback;
    int length;
} JsFunction;

typedef struct JsModule {
    const char* specifier;
    const JsFunction* functions;
} JsModule;

typedef struct JsRegistryApi {
    uint32_t abi_version;
    int (*add_module)(JsRegistry* registry, const JsModule* module);
} JsRegistryApi;

struct JsRegistry {
    const JsRegistryApi* api;
    void* data;
};

typedef struct JsContextApi {
    uint32_t abi_version;
    JsValue (*undefined)(JsContext* ctx);
    JsValue (*null_value)(JsContext* ctx);
    JsValue (*bool_value)(JsContext* ctx, int value);
    JsValue (*int32_value)(JsContext* ctx, int32_t value);
    JsValue (*float64_value)(JsContext* ctx, double value);
    JsValue (*string_value)(JsContext* ctx, const char* value);
    JsValue (*object_value)(JsContext* ctx);
    int (*set_property)(JsContext* ctx, JsValue object, const char* key, JsValue value);
    int (*to_bool)(JsContext* ctx, JsValue value, int* out);
    int (*to_int32)(JsContext* ctx, JsValue value, int32_t* out);
    int (*to_float64)(JsContext* ctx, JsValue value, double* out);
    const char* (*to_string)(JsContext* ctx, JsValue value);
    JsValue (*throw_type_error)(JsContext* ctx, const char* message);
    JsValue (*throw_error)(JsContext* ctx, const char* message);
} JsContextApi;

struct JsContext {
    const JsContextApi* api;
    void* data;
};

typedef int (*JsRegisterModulesFn)(JsRegistry* registry);

static inline int js_add_module(
    JsRegistry* registry,
    const JsModule* module
) {
    return registry->api->add_module(registry, module);
}

static inline JsValue js_undefined(JsContext* ctx) {
    return ctx->api->undefined(ctx);
}

static inline JsValue js_null(JsContext* ctx) {
    return ctx->api->null_value(ctx);
}

static inline JsValue js_bool(JsContext* ctx, int value) {
    return ctx->api->bool_value(ctx, value);
}

static inline JsValue js_int32(JsContext* ctx, int32_t value) {
    return ctx->api->int32_value(ctx, value);
}

static inline JsValue js_float64(JsContext* ctx, double value) {
    return ctx->api->float64_value(ctx, value);
}

static inline JsValue js_string(JsContext* ctx, const char* value) {
    return ctx->api->string_value(ctx, value);
}

static inline JsValue js_object(JsContext* ctx) {
    return ctx->api->object_value(ctx);
}

static inline int js_set_property(
    JsContext* ctx,
    JsValue object,
    const char* key,
    JsValue value
) {
    return ctx->api->set_property(ctx, object, key, value);
}

static inline int js_to_bool(JsContext* ctx, JsValue value, int* out) {
    return ctx->api->to_bool(ctx, value, out);
}

static inline int js_to_int32(JsContext* ctx, JsValue value, int32_t* out) {
    return ctx->api->to_int32(ctx, value, out);
}

static inline int js_to_float64(JsContext* ctx, JsValue value, double* out) {
    return ctx->api->to_float64(ctx, value, out);
}

static inline const char* js_to_string(JsContext* ctx, JsValue value) {
    return ctx->api->to_string(ctx, value);
}

static inline JsValue js_throw_type_error(JsContext* ctx, const char* message) {
    return ctx->api->throw_type_error(ctx, message);
}

static inline JsValue js_throw_error(JsContext* ctx, const char* message) {
    return ctx->api->throw_error(ctx, message);
}

#ifdef __cplusplus
}
#endif

#endif
