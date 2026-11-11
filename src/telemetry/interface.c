#include "../runtime_host.h"
#include "../runtime_allocator.h"
#include "../../include/addon.h"
#include <math.h>
#include <string.h>

extern int hao_metric_register(JSContext *ctx, const JsMetricDefinition *definition, uint32_t *id);
extern int hao_metric_add(JSContext *ctx, uint32_t id, double delta);
extern int hao_metric_set(JSContext *ctx, uint32_t id, double value);

enum { METRIC_ADD = 1, METRIC_SET = 2, SPAN_START = 3, SPAN_EVENT = 4, SPAN_END = 5 };
enum { ATTRIBUTE_BOOL = 0, ATTRIBUTE_INT = 1, ATTRIBUTE_FLOAT = 2, ATTRIBUTE_TEXT = 3 };

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
    HaoRuntime *host;
    HaoTelemetryItem *pending;
    uint64_t trace_id, span_id, parent_id;
    char *name;
    size_t name_len;
    bool sampled;
};

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

static void enqueue(HaoRuntime *host, HaoTelemetryItem *item) {
    if (!item || item->invalid) { free_item(item); return; }
    pthread_mutex_lock(&host->telemetry_mutex);
    if (host->telemetry_tail) host->telemetry_tail->next = item;
    else host->telemetry_head = item;
    host->telemetry_tail = item;
    pthread_mutex_unlock(&host->telemetry_mutex);
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
    enqueue((HaoRuntime *)handle, item);
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
    HaoRuntime *host = (HaoRuntime *)handle;
    HaoNativeSpan *span = hao_calloc(1, sizeof(*span));
    if (!span) return 0;
    span->host = host;
    span->span_id = random_id();
    span->trace_id = parent_span ? parent_trace : random_id();
    span->parent_id = parent_span;
    span->sampled = host->telemetry_trace_enabled && parent_sampled != 0;
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
    pthread_mutex_lock(&host->telemetry_mutex);
    span->next = host->telemetry_spans;
    host->telemetry_spans = span;
    pthread_mutex_unlock(&host->telemetry_mutex);
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
    HaoRuntime *host = span->host;
    if (span->pending) hao_telemetry_record_finish(handle, (uintptr_t)span->pending);
    if (span->sampled) {
        HaoTelemetryItem *item = new_item(SPAN_END, (const unsigned char *)span->name, span->name_len);
        if (item) {
            item->timestamp = timestamp;
            item->trace_id = span->trace_id;
            item->span_id = span->span_id;
            item->status = status;
            enqueue(host, item);
        }
    }
    pthread_mutex_lock(&host->telemetry_mutex);
    HaoNativeSpan **link = &host->telemetry_spans;
    while (*link && *link != span) link = &(*link)->next;
    if (*link) *link = span->next;
    pthread_mutex_unlock(&host->telemetry_mutex);
    hao_free(span->name);
    hao_free(span);
}

void hao_telemetry_cleanup(HaoRuntime *host) {
    pthread_mutex_lock(&host->telemetry_mutex);
    HaoTelemetryItem *items = host->telemetry_head;
    HaoNativeSpan *spans = host->telemetry_spans;
    host->telemetry_head = host->telemetry_tail = NULL;
    host->telemetry_spans = NULL;
    pthread_mutex_unlock(&host->telemetry_mutex);
    while (items) { HaoTelemetryItem *next = items->next; free_item(items); items = next; }
    while (spans) {
        HaoNativeSpan *next = spans->next;
        free_item(spans->pending);
        hao_free(spans->name);
        hao_free(spans);
        spans = next;
    }
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
    HaoRuntime *host = JS_GetContextOpaque(ctx);
    pthread_mutex_lock(&host->telemetry_mutex);
    HaoTelemetryItem *items = host->telemetry_head;
    host->telemetry_head = host->telemetry_tail = NULL;
    pthread_mutex_unlock(&host->telemetry_mutex);
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
