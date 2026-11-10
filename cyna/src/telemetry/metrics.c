#include <quickjs.h>
#include <uv.h>
#include "../runtime_allocator.h"
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../../../include/addon.h"

typedef struct {
    uint64_t resident_bytes;
    uint64_t physical_footprint_bytes;
} HaoProcessMemory;
extern HaoProcessMemory hao_process_memory_snapshot(void);
static uint64_t resident_peak_bytes;
static uint64_t physical_footprint_peak_bytes;

typedef struct {
    char *scope, *name, *unit;
    uint32_t kind;
    double value, sum, min, max;
    uint32_t count;
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
    if (!d || !out || !d->scope || !*d->scope || !d->name || !*d->name || d->kind < 1 || d->kind > 3) return -1;
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
    if (!m || m->kind == JS_METRIC_HISTOGRAM || !isfinite(delta) || !isfinite(m->value + delta)) return -1;
    m->value += delta; return 0;
}
int hao_metric_set(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || m->kind != JS_METRIC_GAUGE || !isfinite(value)) return -1;
    m->value = value; return 0;
}
int hao_metric_observe(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || m->kind != JS_METRIC_HISTOGRAM || !isfinite(value) || !isfinite(m->sum + value) || m->count == UINT32_MAX) return -1;
    if (!m->count || value < m->min) m->min = value;
    if (!m->count || value > m->max) m->max = value;
    m->count++; m->sum += value; m->value = m->count; return 0;
}
int hao_metric_value(JSContext *ctx, uint32_t id, double *out) {
    HaoMetric *m = metric_for(ctx, id);
    if (!m || !out) return -1;
    *out = m->value; return 0;
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
    if (argc < 1 || !JS_IsObject(argv[0])) return JS_ThrowTypeError(ctx, "invalid metric definition");
    JSValue scope = JS_GetPropertyStr(ctx, argv[0], "scope");
    JSValue name = JS_GetPropertyStr(ctx, argv[0], "name");
    JSValue kind = JS_GetPropertyStr(ctx, argv[0], "kind");
    JSValue unit = JS_GetPropertyStr(ctx, argv[0], "unit");
    const char *s = JS_IsString(scope) ? JS_ToCString(ctx, scope) : NULL;
    const char *n = JS_IsString(name) ? JS_ToCString(ctx, name) : NULL;
    const char *k = JS_IsString(kind) ? JS_ToCString(ctx, kind) : NULL;
    const char *u = JS_IsString(unit) ? JS_ToCString(ctx, unit) : NULL;
    uint32_t metric_kind = k && !strcmp(k, "counter") ? 1 : k && !strcmp(k, "gauge") ? 2 : k && !strcmp(k, "histogram") ? 3 : 0;
    JsMetricDefinition d = {s, n, metric_kind, u};
    uint32_t id = 0;
    int result = (JS_IsUndefined(unit) || u) && hao_metric_register(ctx, &d, &id) == 0;
    if (s) JS_FreeCString(ctx, s); if (n) JS_FreeCString(ctx, n);
    if (k) JS_FreeCString(ctx, k); if (u) JS_FreeCString(ctx, u);
    JS_FreeValue(ctx, scope); JS_FreeValue(ctx, name); JS_FreeValue(ctx, kind); JS_FreeValue(ctx, unit);
    return result ? JS_NewUint32(ctx, id) : JS_ThrowTypeError(ctx, "invalid or conflicting metric definition");
}
static JSValue metric_action_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic) {
    (void)this_val;
    uint32_t id; double value;
    if (argc < 2) return JS_ThrowTypeError(ctx, "metric id and value required");
    if (JS_ToUint32(ctx, &id, argv[0]) < 0 || JS_ToFloat64(ctx, &value, argv[1]) < 0) return JS_EXCEPTION;
    int status = magic == 0 ? hao_metric_add(ctx, id, value) : magic == 1 ? hao_metric_set(ctx, id, value) : hao_metric_observe(ctx, id, value);
    return status == 0 ? JS_UNDEFINED : JS_ThrowTypeError(ctx, "invalid metric operation");
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
        JS_SetPropertyStr(ctx, item, "count", JS_NewUint32(ctx, m->count));
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
    HaoProcessMemory process = hao_process_memory_snapshot();
    if (process.resident_bytes > resident_peak_bytes) resident_peak_bytes = process.resident_bytes;
    if (process.physical_footprint_bytes > physical_footprint_peak_bytes)
        physical_footprint_peak_bytes = process.physical_footprint_bytes;
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
    GAUGE("resident_bytes", process.resident_bytes);
    GAUGE("physical_footprint_bytes", process.physical_footprint_bytes);
    GAUGE("resident_peak_bytes", resident_peak_bytes);
    GAUGE("physical_footprint_peak_bytes", physical_footprint_peak_bytes);
#undef GAUGE
    return result;
}
static JSValue monotonic_time_ns(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewFloat64(ctx, (double)uv_hrtime());
}
void hao_install_telemetry_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_monotonicNs", JS_NewCFunction(ctx, monotonic_time_ns, "monotonicNs", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_memorySnapshot", JS_NewCFunction(ctx, memory_snapshot, "memorySnapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_register", JS_NewCFunction(ctx, metric_register_js, "register", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_add", JS_NewCFunctionMagic(ctx, metric_action_js, "add", 2, JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_set", JS_NewCFunctionMagic(ctx, metric_action_js, "set", 2, JS_CFUNC_generic_magic, 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_observe", JS_NewCFunctionMagic(ctx, metric_action_js, "observe", 2, JS_CFUNC_generic_magic, 2));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_value", JS_NewCFunction(ctx, metric_value_js, "value", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_snapshot", JS_NewCFunction(ctx, metric_snapshot_js, "snapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_clear", JS_NewCFunction(ctx, metric_clear_js, "clear", 0));
}
