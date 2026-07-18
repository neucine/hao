#ifndef HAO_ADDON_H
#define HAO_ADDON_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
#define HAO_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define HAO_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define JS_ADDON_ABI_VERSION 3

#define JS_METRIC_COUNTER 1
#define JS_METRIC_GAUGE 2
#define JS_METRIC_HISTOGRAM 3

/*
 * Hao addon ABI notes:
 *
 * - An addon exports one symbol named `js_register_modules` with the
 *   JsRegisterModulesFn signature. It should check registry->api->abi_version
 *   against JS_ADDON_ABI_VERSION before registering modules.
 * - JsModule.functions must point to a stable array of JsFunction values with
 *   function_count entries.
 * - JsModule, JsFunction, function names, and specifier strings must remain
 *   valid for as long as the dynamic library is loaded.
 * - JsValue handles are only valid during the native callback that received or
 *   created them. Do not store JsValue values across callbacks.
 * - Values returned by js_string, js_object, js_get_property, js_array_get, and
 *   throw helpers are owned by the current callback frame. Return them directly
 *   or pass them to other ABI helpers during the same callback.
 * - js_to_string returns a pointer owned by the current callback frame. Copy it
 *   if it must outlive the callback.
 */

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
    size_t function_count;
} JsModule;

typedef struct JsMetricDefinition {
    const char* scope;
    const char* name;
    uint32_t kind;
    const char* unit;
} JsMetricDefinition;

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
    int (*to_bool)(JsContext* ctx, JsValue value, int* out);
    int (*to_int32)(JsContext* ctx, JsValue value, int32_t* out);
    int (*to_float64)(JsContext* ctx, JsValue value, double* out);
    const char* (*to_string)(JsContext* ctx, JsValue value);
    JsValue (*throw_type_error)(JsContext* ctx, const char* message);
    JsValue (*throw_error)(JsContext* ctx, const char* message);
    JsValue (*object_value)(JsContext* ctx);
    int (*set_property)(JsContext* ctx, JsValue object, const char* key, JsValue value);
    JsValue (*get_property)(JsContext* ctx, JsValue object, const char* key);
    int (*is_undefined)(JsContext* ctx, JsValue value);
    int (*is_null)(JsContext* ctx, JsValue value);
    int (*is_object)(JsContext* ctx, JsValue value);
    int (*is_array)(JsContext* ctx, JsValue value);
    int (*is_function)(JsContext* ctx, JsValue value);
    int (*array_length)(JsContext* ctx, JsValue value, uint32_t* out);
    JsValue (*array_get)(JsContext* ctx, JsValue value, uint32_t index);
    JsValue (*array_value)(JsContext* ctx);
    int (*array_set)(JsContext* ctx, JsValue array, uint32_t index, JsValue value);
    int (*metric_register)(JsContext* ctx, const JsMetricDefinition* definition, uint32_t* out_id);
    int (*metric_add)(JsContext* ctx, uint32_t id, double delta);
    int (*metric_set)(JsContext* ctx, uint32_t id, double value);
    int (*metric_observe)(JsContext* ctx, uint32_t id, double value);
    int (*metric_value)(JsContext* ctx, uint32_t id, double* out);
} JsContextApi;

struct JsContext {
    const JsContextApi* api;
    void* data;
};

typedef int (*JsRegisterModulesFn)(JsRegistry* registry);

HAO_STATIC_ASSERT(sizeof(JsValue) == sizeof(uintptr_t), "JsValue must fit uintptr_t");
HAO_STATIC_ASSERT(offsetof(JsContext, api) == 0, "JsContext.api offset changed");
HAO_STATIC_ASSERT(offsetof(JsContext, data) == sizeof(void*), "JsContext.data offset changed");
HAO_STATIC_ASSERT(sizeof(JsContext) == sizeof(void*) * 2, "JsContext size changed");
HAO_STATIC_ASSERT(offsetof(JsRegistry, api) == 0, "JsRegistry.api offset changed");
HAO_STATIC_ASSERT(offsetof(JsRegistry, data) == sizeof(void*), "JsRegistry.data offset changed");
HAO_STATIC_ASSERT(sizeof(JsRegistry) == sizeof(void*) * 2, "JsRegistry size changed");
HAO_STATIC_ASSERT(offsetof(JsFunction, name) == 0, "JsFunction.name offset changed");
HAO_STATIC_ASSERT(offsetof(JsFunction, callback) == sizeof(void*), "JsFunction.callback offset changed");
HAO_STATIC_ASSERT(offsetof(JsFunction, length) == sizeof(void*) * 2, "JsFunction.length offset changed");
HAO_STATIC_ASSERT(offsetof(JsModule, specifier) == 0, "JsModule.specifier offset changed");
HAO_STATIC_ASSERT(offsetof(JsModule, functions) == sizeof(void*), "JsModule.functions offset changed");
HAO_STATIC_ASSERT(offsetof(JsModule, function_count) == sizeof(void*) * 2, "JsModule.function_count offset changed");
HAO_STATIC_ASSERT(sizeof(JsModule) == sizeof(void*) * 3, "JsModule size changed");
HAO_STATIC_ASSERT(offsetof(JsMetricDefinition, scope) == 0, "JsMetricDefinition.scope offset changed");
HAO_STATIC_ASSERT(offsetof(JsMetricDefinition, name) == sizeof(void*), "JsMetricDefinition.name offset changed");
HAO_STATIC_ASSERT(offsetof(JsMetricDefinition, kind) == sizeof(void*) * 2, "JsMetricDefinition.kind offset changed");
HAO_STATIC_ASSERT(offsetof(JsMetricDefinition, unit) == sizeof(void*) * 3, "JsMetricDefinition.unit offset changed");
HAO_STATIC_ASSERT(sizeof(JsMetricDefinition) == sizeof(void*) * 4, "JsMetricDefinition size changed");
HAO_STATIC_ASSERT(offsetof(JsRegistryApi, abi_version) == 0, "JsRegistryApi.abi_version offset changed");
HAO_STATIC_ASSERT(offsetof(JsRegistryApi, add_module) == sizeof(void*), "JsRegistryApi.add_module offset changed");
HAO_STATIC_ASSERT(sizeof(JsRegistryApi) == sizeof(void*) * 2, "JsRegistryApi size changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, abi_version) == 0, "JsContextApi.abi_version offset changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, undefined) == sizeof(void*), "JsContextApi.undefined offset changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, null_value) == sizeof(void*) * 2, "JsContextApi.null_value offset changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, array_set) == sizeof(void*) * 24, "JsContextApi.array_set offset changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, metric_register) == sizeof(void*) * 25, "JsContextApi.metric_register offset changed");
HAO_STATIC_ASSERT(offsetof(JsContextApi, metric_value) == sizeof(void*) * 29, "JsContextApi.metric_value offset changed");
HAO_STATIC_ASSERT(sizeof(JsContextApi) == sizeof(void*) * 30, "JsContextApi size changed");

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

static inline JsValue js_get_property(JsContext* ctx, JsValue object, const char* key) {
    return ctx->api->get_property(ctx, object, key);
}

static inline int js_is_undefined(JsContext* ctx, JsValue value) {
    return ctx->api->is_undefined(ctx, value);
}

static inline int js_is_null(JsContext* ctx, JsValue value) {
    return ctx->api->is_null(ctx, value);
}

static inline int js_is_object(JsContext* ctx, JsValue value) {
    return ctx->api->is_object(ctx, value);
}

static inline int js_is_array(JsContext* ctx, JsValue value) {
    return ctx->api->is_array(ctx, value);
}

static inline int js_is_function(JsContext* ctx, JsValue value) {
    return ctx->api->is_function(ctx, value);
}

static inline int js_array_length(JsContext* ctx, JsValue value, uint32_t* out) {
    return ctx->api->array_length(ctx, value, out);
}

static inline JsValue js_array_get(JsContext* ctx, JsValue value, uint32_t index) {
    return ctx->api->array_get(ctx, value, index);
}

static inline JsValue js_array(JsContext* ctx) {
    return ctx->api->array_value(ctx);
}

static inline int js_array_set(
    JsContext* ctx,
    JsValue array,
    uint32_t index,
    JsValue value
) {
    return ctx->api->array_set(ctx, array, index, value);
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

static inline int js_metric_register(
    JsContext* ctx,
    const JsMetricDefinition* definition,
    uint32_t* out_id
) {
    return ctx->api->metric_register(ctx, definition, out_id);
}

static inline int js_metric_add(JsContext* ctx, uint32_t id, double delta) {
    return ctx->api->metric_add(ctx, id, delta);
}

static inline int js_metric_set(JsContext* ctx, uint32_t id, double value) {
    return ctx->api->metric_set(ctx, id, value);
}

static inline int js_metric_observe(JsContext* ctx, uint32_t id, double value) {
    return ctx->api->metric_observe(ctx, id, value);
}

static inline int js_metric_value(JsContext* ctx, uint32_t id, double* out) {
    return ctx->api->metric_value(ctx, id, out);
}

#undef HAO_STATIC_ASSERT

#ifdef __cplusplus
}
#endif

#endif
