#include "metrics.h"
#include "../process_memory.h"
#include <quickjs.h>
#include <uv.h>
#include "../runtime_allocator.h"
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../../../include/addon.h"

static uint64_t resident_peak_bytes;
static uint64_t physical_footprint_peak_bytes;

typedef struct {
    char *scope, *name, *unit;
    uint32_t kind;
    double value, sum, min, max;
    uint64_t count;
} HaoMetric;

typedef struct HaoMetricRegistry {
    JSContext *ctx;
    HaoMetric entries[256];
    uint32_t count;
    struct HaoMetricRegistry *next;
} HaoMetricRegistry;

static HaoMetricRegistry *registries;

static HaoMetricRegistry *registry_for(JSContext *ctx, int create) {
    for (HaoMetricRegistry *r = registries; r; r = r->next) if (r->ctx == ctx) return r;
    if (!create) return NULL;
    HaoMetricRegistry *r = hao_calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->ctx = ctx; r->next = registries; registries = r;
    return r;
}

int hao_metric_register(JSContext *ctx, const JsMetricDefinition *d, uint32_t *out) {
    if (!d || !out || !hao_metric_definition_valid((const unsigned char *)d->scope,
            (const unsigned char *)d->name, d->kind, (const unsigned char *)d->unit)) return -1;
    const char *unit = d->unit ? d->unit : "";
    HaoMetricRegistry *r = registry_for(ctx, 1);
    if (!r) return -1;
    for (uint32_t i = 0; i < r->count; i++) {
        HaoMetric *m = &r->entries[i];
        if (!strcmp(m->scope, d->scope) && !strcmp(m->name, d->name)) {
            if (m->kind != d->kind || strcmp(m->unit, unit)) return -1;
            *out = i; return 0;
        }
    }
    if (r->count == 256) return -1;
    HaoMetric *m = &r->entries[r->count];
    m->scope = hao_strdup(d->scope); m->name = hao_strdup(d->name); m->unit = hao_strdup(unit);
    if (!m->scope || !m->name || !m->unit) {
        hao_free(m->scope); hao_free(m->name); hao_free(m->unit); memset(m, 0, sizeof(*m)); return -1;
    }
    m->kind = d->kind; *out = r->count++; return 0;
}

static HaoMetric *metric_for(JSContext *ctx, uint32_t id) {
    HaoMetricRegistry *r = registry_for(ctx, 0);
    return r && id < r->count ? &r->entries[id] : NULL;
}
int hao_metric_add(JSContext *ctx, uint32_t id, double delta) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || !hao_metric_can_add(m->kind, delta)) return -1;
    m->value += delta; return 0;
}
int hao_metric_set(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || !hao_metric_can_set(m->kind, value)) return -1;
    m->value = value; return 0;
}
int hao_metric_observe(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || !hao_metric_can_observe(m->kind)) return -1;
    if (!m->count) { m->min = value; m->max = value; }
    else { m->min = fmin(m->min, value); m->max = fmax(m->max, value); }
    m->count++; m->sum += value; return 0;
}
int hao_metric_value(JSContext *ctx, uint32_t id, double *out) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || !out) return -1;
    *out = m->kind == JS_METRIC_HISTOGRAM ? (double)m->count : m->value; return 0;
}
static void clear_registry(HaoMetricRegistry *r) {
    for (uint32_t i = 0; i < r->count; i++) {
        hao_free(r->entries[i].scope); hao_free(r->entries[i].name); hao_free(r->entries[i].unit);
        memset(&r->entries[i], 0, sizeof(r->entries[i]));
    }
    r->count = 0;
}
void hao_metric_cleanup(JSContext *ctx) {
    HaoMetricRegistry **link = &registries;
    while (*link) {
        HaoMetricRegistry *r = *link;
        if (r->ctx != ctx) { link = &r->next; continue; }
        *link = r->next; clear_registry(r); hao_free(r);
    }
}

static JSValue metric_register_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0])) return JS_ThrowTypeError(ctx, "registerMetric requires a definition object");
    JSValue scope = JS_GetPropertyStr(ctx, argv[0], "scope");
    JSValue name = JS_GetPropertyStr(ctx, argv[0], "name");
    JSValue kind = JS_GetPropertyStr(ctx, argv[0], "kind");
    JSValue unit = JS_GetPropertyStr(ctx, argv[0], "unit");
    size_t s_len = 0, n_len = 0, k_len = 0, u_len = 0;
    const char *s = !JS_IsNull(scope) && !JS_IsUndefined(scope) ? JS_ToCStringLen(ctx, &s_len, scope) : NULL;
    const char *n = !JS_IsNull(name) && !JS_IsUndefined(name) ? JS_ToCStringLen(ctx, &n_len, name) : NULL;
    const char *k = !JS_IsNull(kind) && !JS_IsUndefined(kind) ? JS_ToCStringLen(ctx, &k_len, kind) : NULL;
    const char *u = !JS_IsNull(unit) && !JS_IsUndefined(unit) ? JS_ToCStringLen(ctx, &u_len, unit) : NULL;
    uint32_t metric_kind = k && hao_metric_text_valid((const unsigned char *)k, k_len, 1) ? hao_metric_kind((const unsigned char *)k) : 0;
    JsMetricDefinition d = {s, n, metric_kind, u};
    uint32_t id = 0;
    int valid = s && n && k && metric_kind &&
        hao_metric_text_valid((const unsigned char *)s, s_len, 1) &&
        hao_metric_text_valid((const unsigned char *)n, n_len, 1) &&
        (!u || hao_metric_text_valid((const unsigned char *)u, u_len, 0));
    int result = valid && hao_metric_register(ctx, &d, &id) == 0;
    const char *error = !s ? "metric scope must be a string" : !n ? "metric name must be a string"
        : !k ? "metric kind must be a string" : !metric_kind ? "metric kind must be counter, gauge, or histogram"
        : "failed to register metric";
    if (s) JS_FreeCString(ctx, s); if (n) JS_FreeCString(ctx, n);
    if (k) JS_FreeCString(ctx, k); if (u) JS_FreeCString(ctx, u);
    JS_FreeValue(ctx, scope); JS_FreeValue(ctx, name); JS_FreeValue(ctx, kind); JS_FreeValue(ctx, unit);
    if (result) return JS_NewUint32(ctx, id);
    if (!s || !n || !k || !metric_kind) return JS_ThrowTypeError(ctx, "%s", error);
    return JS_ThrowInternalError(ctx, "%s", error);
}
static JSValue metric_action_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic) {
    (void)this_val;
    int32_t signed_id; double value;
    const char *action = magic == 0 ? "add" : magic == 1 ? "set" : "observe";
    if (argc < 2) return JS_ThrowTypeError(ctx, "%sMetric requires id and %s", action,
                                           magic == 0 ? "delta" : "value");
    if (JS_ToInt32(ctx, &signed_id, argv[0]) < 0 || signed_id < 0) {
        JSValue error = JS_GetException(ctx); JS_FreeValue(ctx, error);
        return JS_ThrowTypeError(ctx, "metric id must be a non-negative integer");
    }
    if (JS_ToFloat64(ctx, &value, argv[1]) < 0) {
        JSValue error = JS_GetException(ctx); JS_FreeValue(ctx, error);
        return JS_ThrowTypeError(ctx, magic == 0 ? "metric delta must be a number" : "metric value must be a number");
    }
    uint32_t id = (uint32_t)signed_id;
    int status = magic == 0 ? hao_metric_add(ctx, id, value) : magic == 1 ? hao_metric_set(ctx, id, value) : hao_metric_observe(ctx, id, value);
    return status == 0 ? JS_UNDEFINED : JS_ThrowInternalError(ctx, "failed to %s metric", action);
}
static JSValue metric_value_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id; double value;
    if (argc < 1) return JS_ThrowTypeError(ctx, "metric id required");
    if (JS_ToUint32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    return hao_metric_value(ctx, id, &value) == 0 ? JS_NewFloat64(ctx, value) : JS_ThrowTypeError(ctx, "invalid metric id");
}
static JSValue metric_snapshot_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    HaoMetricRegistry *r = registry_for(ctx, 0);
    JSValue array = JS_NewArray(ctx);
    if (JS_IsException(array)) return array;
    for (uint32_t i = 0; r && i < r->count; i++) {
        HaoMetric *m = &r->entries[i];
        JSValue item = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, item, "id", JS_NewUint32(ctx, i));
        JS_SetPropertyStr(ctx, item, "scope", JS_NewString(ctx, m->scope));
        JS_SetPropertyStr(ctx, item, "name", JS_NewString(ctx, m->name));
        JS_SetPropertyStr(ctx, item, "kind", JS_NewString(ctx, m->kind == 1 ? "counter" : m->kind == 2 ? "gauge" : "histogram"));
        JS_SetPropertyStr(ctx, item, "unit", JS_NewString(ctx, m->unit));
        JS_SetPropertyStr(ctx, item, "value", JS_NewFloat64(ctx, m->value));
        JS_SetPropertyStr(ctx, item, "count", JS_NewFloat64(ctx, (double)m->count));
        JS_SetPropertyStr(ctx, item, "sum", JS_NewFloat64(ctx, m->sum));
        JS_SetPropertyStr(ctx, item, "min", JS_NewFloat64(ctx, m->min));
        JS_SetPropertyStr(ctx, item, "max", JS_NewFloat64(ctx, m->max));
        JS_SetPropertyUint32(ctx, array, i, item);
    }
    return array;
}
static JSValue metric_clear_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    HaoMetricRegistry *r = registry_for(ctx, 0); if (r) clear_registry(r);
    return JS_UNDEFINED;
}

static JSValue memory_snapshot(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(JS_GetRuntime(ctx), &usage);
    HaoAllocatorStats allocator = hao_allocator_stats();
    uint64_t resident_bytes = 0, physical_footprint_bytes = 0;
    hao_process_memory_snapshot(&resident_bytes, &physical_footprint_bytes);
    if (resident_bytes > resident_peak_bytes) resident_peak_bytes = resident_bytes;
    if (physical_footprint_bytes > physical_footprint_peak_bytes)
        physical_footprint_peak_bytes = physical_footprint_bytes;
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
#define GAUGE(name, value) JS_SetPropertyStr(ctx, result, name, JS_NewFloat64(ctx, (double)(value)))
    GAUGE("qjs_malloc_bytes", usage.malloc_size);
    GAUGE("qjs_malloc_limit_bytes", usage.malloc_limit);
    GAUGE("qjs_heap_used_bytes", usage.memory_used_size);
    GAUGE("qjs_malloc_count", usage.malloc_count);
    GAUGE("qjs_heap_used_count", usage.memory_used_count);
    GAUGE("qjs_atom_count", usage.atom_count);
    GAUGE("qjs_atom_bytes", usage.atom_size);
    GAUGE("qjs_string_count", usage.str_count);
    GAUGE("qjs_string_bytes", usage.str_size);
    GAUGE("qjs_object_count", usage.obj_count);
    GAUGE("qjs_object_bytes", usage.obj_size);
    GAUGE("qjs_property_count", usage.prop_count);
    GAUGE("qjs_property_bytes", usage.prop_size);
    GAUGE("qjs_shape_count", usage.shape_count);
    GAUGE("qjs_shape_bytes", usage.shape_size);
    GAUGE("qjs_function_count", usage.js_func_count);
    GAUGE("qjs_function_bytes", usage.js_func_size);
    GAUGE("qjs_function_code_bytes", usage.js_func_code_size);
    GAUGE("qjs_array_count", usage.array_count);
    GAUGE("qjs_fast_array_count", usage.fast_array_count);
    GAUGE("qjs_fast_array_element_count", usage.fast_array_elements);
    GAUGE("qjs_binary_object_count", usage.binary_object_count);
    GAUGE("qjs_binary_object_bytes", usage.binary_object_size);
    GAUGE("allocator_active_bytes", allocator.active_size);
    GAUGE("allocator_peak_bytes", allocator.peak_size);
    GAUGE("allocator_allocated_bytes_total", allocator.allocated_size);
    GAUGE("allocator_freed_bytes_total", allocator.freed_size);
    GAUGE("allocator_allocation_count", allocator.allocation_count);
    GAUGE("allocator_free_count", allocator.free_count);
    GAUGE("resident_bytes", resident_bytes);
    GAUGE("physical_footprint_bytes", physical_footprint_bytes);
    GAUGE("resident_peak_bytes", resident_peak_bytes);
    GAUGE("physical_footprint_peak_bytes", physical_footprint_peak_bytes);
#undef GAUGE
    return result;
}
static JSValue monotonic_time_ns(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewFloat64(ctx, (double)uv_hrtime());
}
static JSValue random_hex_id(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t length;
    if (argc < 1 || JS_ToInt32(ctx, &length, argv[0]) < 0) return JS_EXCEPTION;
    if (length != 8 && length != 16) return JS_ThrowRangeError(ctx, "trace ID must use 8 or 16 bytes");
    unsigned char bytes[16];
    if (uv_random(NULL, NULL, bytes, (size_t)length, 0, NULL) != 0)
        return JS_ThrowInternalError(ctx, "unable to generate trace ID");
    static const char hex[] = "0123456789abcdef";
    char encoded[32];
    for (int32_t i = 0; i < length; i++) {
        encoded[i * 2] = hex[bytes[i] >> 4];
        encoded[i * 2 + 1] = hex[bytes[i] & 15];
    }
    return JS_NewStringLen(ctx, encoded, (size_t)length * 2);
}
void hao_install_telemetry_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_monotonicNs", JS_NewCFunction(ctx, monotonic_time_ns, "monotonicNs", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_randomHexId", JS_NewCFunction(ctx, random_hex_id, "randomHexId", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_memorySnapshot", JS_NewCFunction(ctx, memory_snapshot, "memorySnapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_register", JS_NewCFunction(ctx, metric_register_js, "register", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_add", JS_NewCFunctionMagic(ctx, metric_action_js, "add", 2, JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_set", JS_NewCFunctionMagic(ctx, metric_action_js, "set", 2, JS_CFUNC_generic_magic, 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_observe", JS_NewCFunctionMagic(ctx, metric_action_js, "observe", 2, JS_CFUNC_generic_magic, 2));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_value", JS_NewCFunction(ctx, metric_value_js, "value", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_snapshot", JS_NewCFunction(ctx, metric_snapshot_js, "snapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_clear", JS_NewCFunction(ctx, metric_clear_js, "clear", 0));
}
