#include "allocator.h"
#include "telemetry.h"
#include <math.h>
#include <pthread.h>
#include <quickjs.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

/* Cyna export used to include host memory in the native telemetry snapshot. */
extern void hao_process_memory_snapshot(uint64_t *resident_bytes,
                                        uint64_t *physical_footprint_bytes);

/* Metrics and host memory gauges. */
static _Atomic uint64_t resident_peak_bytes;
static _Atomic uint64_t physical_footprint_peak_bytes;

static uint64_t update_peak(_Atomic uint64_t *peak, uint64_t value) {
    uint64_t current = atomic_load_explicit(peak, memory_order_relaxed);
    while (value > current && !atomic_compare_exchange_weak_explicit(
            peak, &current, value, memory_order_relaxed, memory_order_relaxed)) {}
    return atomic_load_explicit(peak, memory_order_relaxed);
}

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
    uint64_t resident_peak = update_peak(&resident_peak_bytes, resident_bytes);
    uint64_t physical_footprint_peak = update_peak(&physical_footprint_peak_bytes, physical_footprint_bytes);
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
    GAUGE("resident_peak_bytes", resident_peak);
    GAUGE("physical_footprint_peak_bytes", physical_footprint_peak);
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

/* Native spans, records, and QuickJS callbacks. */
enum { METRIC_ADD = 1, METRIC_SET = 2, SPAN_START = 3, SPAN_EVENT = 4, SPAN_END = 5 };
enum { ATTRIBUTE_BOOL = 0, ATTRIBUTE_INT = 1, ATTRIBUTE_FLOAT = 2, ATTRIBUTE_TEXT = 3 };

typedef struct HaoTelemetryItem HaoTelemetryItem;
typedef struct HaoNativeSpan HaoNativeSpan;
typedef struct HaoTelemetry HaoTelemetry;

typedef struct {
    char *key;
    size_t key_len;
    int kind;
    int boolean;
    int64_t integer;
    double floating;
    char *text;
    size_t text_len;
} HaoNativeAttribute;

struct HaoTelemetryItem {
    struct HaoTelemetryItem *next;
    int kind;
    char *scope, *name;
    size_t name_len;
    int metric_kind, metric_unit;
    double value;
    int64_t timestamp;
    uint64_t trace_id, span_id, parent_id;
    int status;
    HaoNativeAttribute attributes[16];
    size_t attribute_count;
    bool invalid;
};

struct HaoNativeSpan {
    struct HaoNativeSpan *next;
    HaoTelemetry *host;
    HaoTelemetryItem *pending;
    uint64_t trace_id, span_id, parent_id;
    char *name;
    size_t name_len;
    bool sampled;
};

struct HaoTelemetry {
    uintptr_t runtime;
    pthread_mutex_t mutex;
    HaoTelemetryItem *head;
    HaoTelemetryItem *tail;
    HaoNativeSpan *spans;
    bool enabled;
    struct HaoTelemetry *next;
};

static pthread_mutex_t runtimes_mutex = PTHREAD_MUTEX_INITIALIZER;
static HaoTelemetry *runtimes;

uintptr_t hao_telemetry_open(uintptr_t runtime) {
    if (!runtime) return 0;
    HaoTelemetry *telemetry = hao_calloc(1, sizeof(*telemetry));
    if (!telemetry) return 0;
    if (pthread_mutex_init(&telemetry->mutex, NULL) != 0) {
        hao_free(telemetry);
        return 0;
    }
    telemetry->runtime = runtime;
    pthread_mutex_lock(&runtimes_mutex);
    telemetry->next = runtimes;
    runtimes = telemetry;
    pthread_mutex_unlock(&runtimes_mutex);
    return (uintptr_t)telemetry;
}

static HaoTelemetry *telemetry_for(uintptr_t runtime) {
    HaoTelemetry *result = NULL;
    pthread_mutex_lock(&runtimes_mutex);
    for (HaoTelemetry *telemetry = runtimes; telemetry; telemetry = telemetry->next) {
        if (telemetry->runtime == runtime) {
            result = telemetry;
            break;
        }
    }
    pthread_mutex_unlock(&runtimes_mutex);
    return result;
}

void hao_telemetry_set_enabled(uintptr_t handle, int enabled) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (telemetry) telemetry->enabled = enabled != 0;
}

static char *copy_text(const unsigned char *text, size_t length) {
    if (!text && length) return NULL;
    char *copy = hao_alloc(length + 1);
    if (!copy) return NULL;
    if (length) memcpy(copy, text, length);
    copy[length] = 0;
    return copy;
}

static void free_item(HaoTelemetryItem *item) {
    if (!item) return;
    hao_free(item->scope);
    hao_free(item->name);
    for (size_t i = 0; i < item->attribute_count; i++) {
        hao_free(item->attributes[i].key);
        hao_free(item->attributes[i].text);
    }
    hao_free(item);
}

static HaoTelemetryItem *new_item(int kind, const unsigned char *name, size_t length) {
    if (length > 255) return NULL;
    HaoTelemetryItem *item = hao_calloc(1, sizeof(*item));
    if (!item) return NULL;
    item->kind = kind;
    item->name_len = length;
    item->name = copy_text(name, length);
    if (!item->name) { free_item(item); return NULL; }
    return item;
}

static void enqueue(HaoTelemetry *telemetry, HaoTelemetryItem *item) {
    if (!item || item->invalid) { free_item(item); return; }
    pthread_mutex_lock(&telemetry->mutex);
    if (telemetry->tail) telemetry->tail->next = item;
    else telemetry->head = item;
    telemetry->tail = item;
    pthread_mutex_unlock(&telemetry->mutex);
}

void hao_telemetry_metric(uintptr_t handle, const unsigned char *scope, size_t scope_len,
                          const unsigned char *name, size_t name_len, int kind, int unit,
                          int64_t value, int set) {
    if (!handle || !scope_len || !name_len || scope_len > 255 || name_len > 255) return;
    HaoTelemetryItem *item = new_item(set ? METRIC_SET : METRIC_ADD, name, name_len);
    if (!item) return;
    item->scope = copy_text(scope, scope_len);
    item->metric_kind = kind;
    item->metric_unit = unit;
    item->value = (double)value;
    if (!item->scope) { free_item(item); return; }
    HaoTelemetry *telemetry = telemetry_for(handle);
    if (telemetry) enqueue(telemetry, item);
    else free_item(item);
}

static uint64_t random_id(void) {
    uint64_t id = 0;
    if (uv_random(NULL, NULL, &id, sizeof(id), 0, NULL) != 0 || id == 0) return 0;
    return id;
}

uintptr_t hao_telemetry_span_start(uintptr_t handle, uint64_t parent_trace, uint64_t parent_span,
                                    int parent_sampled, int64_t timestamp,
                                    const unsigned char *name, size_t name_len, int span_kind) {
    (void)span_kind;
    if (!handle || name_len > 96) return 0;
    HaoTelemetry *telemetry = telemetry_for(handle);
    if (!telemetry) return 0;
    HaoNativeSpan *span = hao_calloc(1, sizeof(*span));
    if (!span) return 0;
    span->host = telemetry;
    span->span_id = random_id();
    span->trace_id = parent_span ? parent_trace : random_id();
    span->parent_id = parent_span;
    span->sampled = telemetry->enabled && parent_sampled != 0;
    span->name = copy_text(name, name_len);
    span->name_len = name_len;
    if (!span->span_id || !span->trace_id || !span->name) {
        hao_free(span->name); hao_free(span); return 0;
    }
    if (span->sampled) {
        span->pending = new_item(SPAN_START, name, name_len);
        if (!span->pending) span->sampled = false;
        else {
            span->pending->timestamp = timestamp;
            span->pending->trace_id = span->trace_id;
            span->pending->span_id = span->span_id;
            span->pending->parent_id = parent_span;
        }
    }
    pthread_mutex_lock(&telemetry->mutex);
    span->next = telemetry->spans;
    telemetry->spans = span;
    pthread_mutex_unlock(&telemetry->mutex);
    return (uintptr_t)span;
}

uint64_t hao_telemetry_span_trace(uintptr_t handle) { return handle ? ((HaoNativeSpan *)handle)->trace_id : 0; }
uint64_t hao_telemetry_span_id(uintptr_t handle) { return handle ? ((HaoNativeSpan *)handle)->span_id : 0; }
int hao_telemetry_span_sampled(uintptr_t handle) { return handle && ((HaoNativeSpan *)handle)->sampled; }

uintptr_t hao_telemetry_span_pending(uintptr_t handle) {
    return handle ? (uintptr_t)((HaoNativeSpan *)handle)->pending : 0;
}

uintptr_t hao_telemetry_event_start(uintptr_t handle, int64_t timestamp,
                                     const unsigned char *name, size_t name_len) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    if (!span || !span->sampled || name_len > 96) return 0;
    HaoTelemetryItem *item = new_item(SPAN_EVENT, name, name_len);
    if (!item) return 0;
    item->timestamp = timestamp;
    item->trace_id = span->trace_id;
    item->span_id = span->span_id;
    return (uintptr_t)item;
}

void hao_telemetry_attribute(uintptr_t record, const unsigned char *key, size_t key_len,
                             int kind, int boolean, int64_t integer, double floating,
                             const unsigned char *text, size_t text_len) {
    HaoTelemetryItem *item = (HaoTelemetryItem *)record;
    if (!item || item->invalid) return;
    if (item->attribute_count == 16 || key_len > 64 || text_len > 256 ||
        kind < ATTRIBUTE_BOOL || kind > ATTRIBUTE_TEXT ||
        (kind == ATTRIBUTE_FLOAT && !isfinite(floating))) { item->invalid = true; return; }
    HaoNativeAttribute *attr = &item->attributes[item->attribute_count];
    attr->key = copy_text(key, key_len);
    attr->text = kind == ATTRIBUTE_TEXT ? copy_text(text, text_len) : NULL;
    if (!attr->key || (kind == ATTRIBUTE_TEXT && !attr->text)) {
        hao_free(attr->key); hao_free(attr->text); item->invalid = true; return;
    }
    attr->kind = kind;
    attr->key_len = key_len;
    attr->text_len = text_len;
    attr->boolean = boolean;
    attr->integer = integer;
    attr->floating = floating;
    item->attribute_count++;
}

void hao_telemetry_record_finish(uintptr_t handle, uintptr_t record) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    HaoTelemetryItem *item = (HaoTelemetryItem *)record;
    if (!span || !item) return;
    if (span->pending == item) {
        span->pending = NULL;
        if (item->invalid) span->sampled = false;
    }
    enqueue(span->host, item);
}

void hao_telemetry_span_end(uintptr_t handle, int64_t timestamp, int status) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    if (!span) return;
    HaoTelemetry *telemetry = span->host;
    if (span->pending) hao_telemetry_record_finish(handle, (uintptr_t)span->pending);
    if (span->sampled) {
        HaoTelemetryItem *item = new_item(SPAN_END, (const unsigned char *)span->name, span->name_len);
        if (item) {
            item->timestamp = timestamp;
            item->trace_id = span->trace_id;
            item->span_id = span->span_id;
            item->status = status;
            enqueue(telemetry, item);
        }
    }
    pthread_mutex_lock(&telemetry->mutex);
    HaoNativeSpan **link = &telemetry->spans;
    while (*link && *link != span) link = &(*link)->next;
    if (*link) *link = span->next;
    pthread_mutex_unlock(&telemetry->mutex);
    hao_free(span->name);
    hao_free(span);
}

void hao_telemetry_close(uintptr_t handle) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry) return;
    pthread_mutex_lock(&runtimes_mutex);
    HaoTelemetry **runtime_link = &runtimes;
    while (*runtime_link && *runtime_link != telemetry) runtime_link = &(*runtime_link)->next;
    if (*runtime_link) *runtime_link = telemetry->next;
    pthread_mutex_unlock(&runtimes_mutex);
    pthread_mutex_lock(&telemetry->mutex);
    HaoTelemetryItem *items = telemetry->head;
    HaoNativeSpan *spans = telemetry->spans;
    telemetry->head = telemetry->tail = NULL;
    telemetry->spans = NULL;
    pthread_mutex_unlock(&telemetry->mutex);
    while (items) { HaoTelemetryItem *next = items->next; free_item(items); items = next; }
    while (spans) {
        HaoNativeSpan *next = spans->next;
        free_item(spans->pending);
        hao_free(spans->name);
        hao_free(spans);
        spans = next;
    }
    pthread_mutex_destroy(&telemetry->mutex);
    hao_free(telemetry);
}

static void hex64(uint64_t value, char out[17]) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 15; i >= 0; i--) { out[i] = hex[value & 15]; value >>= 4; }
    out[16] = 0;
}

static JSValue record_js(JSContext *ctx, HaoTelemetryItem *item) {
    JSValue record = JS_NewObject(ctx);
    char trace[33] = "0000000000000000", span[17], parent[17];
    hex64(item->trace_id, trace + 16);
    hex64(item->span_id, span);
    hex64(item->parent_id, parent);
    JS_SetPropertyStr(ctx, record, "kind", JS_NewString(ctx, item->kind == SPAN_START ? "span_start" : item->kind == SPAN_EVENT ? "event" : "span_end"));
    JS_SetPropertyStr(ctx, record, "timestamp_ns", JS_NewFloat64(ctx, (double)item->timestamp));
    JS_SetPropertyStr(ctx, record, "trace_id", JS_NewString(ctx, trace));
    JS_SetPropertyStr(ctx, record, "span_id", JS_NewString(ctx, span));
    JS_SetPropertyStr(ctx, record, "parent_span_id", JS_NewString(ctx, parent));
    JS_SetPropertyStr(ctx, record, "name", JS_NewStringLen(ctx, item->name, item->name_len));
    JS_SetPropertyStr(ctx, record, "status", JS_NewString(ctx, item->status == 1 ? "ok" : item->status == 2 ? "err" : "unset"));
    JSValue attributes = JS_NewObject(ctx);
    for (size_t i = 0; i < item->attribute_count; i++) {
        HaoNativeAttribute *attr = &item->attributes[i];
        JSValue value = attr->kind == ATTRIBUTE_BOOL ? JS_NewBool(ctx, attr->boolean) :
                        attr->kind == ATTRIBUTE_INT ? JS_NewInt64(ctx, attr->integer) :
                        attr->kind == ATTRIBUTE_FLOAT ? JS_NewFloat64(ctx, attr->floating) :
                        JS_NewStringLen(ctx, attr->text, attr->text_len);
        JSAtom key = JS_NewAtomLen(ctx, attr->key, attr->key_len);
        JS_SetProperty(ctx, attributes, key, value);
        JS_FreeAtom(ctx, key);
    }
    JS_SetPropertyStr(ctx, record, "attributes", attributes);
    return record;
}

static JSValue drain_js(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    HaoTelemetry *telemetry = telemetry_for((uintptr_t)JS_GetContextOpaque(ctx));
    if (!telemetry) return JS_NewArray(ctx);
    pthread_mutex_lock(&telemetry->mutex);
    HaoTelemetryItem *items = telemetry->head;
    telemetry->head = telemetry->tail = NULL;
    pthread_mutex_unlock(&telemetry->mutex);
    JSValue records = JS_NewArray(ctx);
    uint32_t index = 0;
    while (items) {
        HaoTelemetryItem *item = items;
        items = item->next;
        if (item->kind == METRIC_ADD || item->kind == METRIC_SET) {
            const char *units[] = { "count", "bytes", "nanoseconds" };
            JsMetricDefinition definition = { item->scope, item->name,
                item->metric_kind == 0 ? JS_METRIC_COUNTER : JS_METRIC_GAUGE,
                units[item->metric_unit < 0 || item->metric_unit > 2 ? 0 : item->metric_unit] };
            uint32_t id;
            if (hao_metric_register(ctx, &definition, &id) == 0) {
                if (item->kind == METRIC_ADD) hao_metric_add(ctx, id, item->value);
                else hao_metric_set(ctx, id, item->value);
            }
        } else {
            JS_SetPropertyUint32(ctx, records, index++, record_js(ctx, item));
        }
        free_item(item);
    }
    return records;
}

void hao_install_telemetry_interface(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_drainNative", JS_NewCFunction(ctx, drain_js, "drainNative", 0));
}
