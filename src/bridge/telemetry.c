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

/* Cyna export used to include host memory in the native metric snapshot. */
extern void hao_process_memory_snapshot(uint64_t *resident_bytes,
                                        uint64_t *physical_footprint_bytes);

enum {
    METRIC_ADD = 1,
    METRIC_SET = 2,
    SPAN_START = 3,
    SPAN_EVENT = 4,
    SPAN_END = 5
};

enum {
    ATTRIBUTE_BOOL = 0,
    ATTRIBUTE_INT = 1,
    ATTRIBUTE_FLOAT = 2,
    ATTRIBUTE_TEXT = 3
};

enum {
    TRACE_STATUS_UNSET = 0,
    TRACE_STATUS_OK = 1,
    TRACE_STATUS_ERR = 2
};

typedef struct HaoTelemetry HaoTelemetry;
typedef struct HaoNativeSpan HaoNativeSpan;
typedef struct HaoTraceScope HaoTraceScope;

typedef struct {
    char *key;
    size_t key_len;
    int kind;
    int boolean;
    int64_t integer;
    double floating;
    char *text;
    size_t text_len;
} HaoTraceAttribute;

typedef struct HaoTraceRecord {
    struct HaoTraceRecord *next;
    uint64_t sequence;
    int kind;
    int64_t timestamp;
    uint64_t trace_id;
    uint64_t span_id;
    uint64_t parent_id;
    char *name;
    size_t name_len;
    int status;
    int span_kind;
    char *source_kind;
    size_t source_kind_len;
    char *source;
    size_t source_len;
    HaoTraceAttribute attributes[16];
    size_t attribute_count;
    bool invalid;
} HaoTraceRecord;

struct HaoNativeSpan {
    HaoNativeSpan *next;
    HaoTelemetry *telemetry;
    uint32_t public_id;
    uint64_t trace_id;
    uint64_t span_id;
    uint64_t parent_id;
    char *name;
    size_t name_len;
    char *source_kind;
    size_t source_kind_len;
    char *source;
    size_t source_len;
    int span_kind;
    bool sampled;
    HaoTraceRecord *pending;
};

struct HaoTraceScope {
    HaoTraceScope *next;
    uint32_t public_id;
    HaoTraceContext previous;
};

struct HaoTelemetry {
    uintptr_t runtime;
    pthread_mutex_t mutex;

    bool enabled;
    size_t capacity;
    HaoTraceRecord *records;
    size_t record_head;
    size_t record_count;
    uint64_t next_sequence;

    HaoTraceContext current;
    HaoNativeSpan *spans;
    HaoTraceScope *scopes;
    uint32_t next_span_id;
    uint32_t next_scope_id;

    /* Cyna callbacks may run on worker threads and are drained on the JS thread. */
    HaoTraceRecord *metric_head;
    HaoTraceRecord *metric_tail;

    struct HaoTelemetry *next;
};

typedef struct {
    char *scope;
    char *name;
    char *unit;
    uint32_t kind;
    double value;
    double sum;
    double min;
    double max;
    uint64_t count;
} HaoMetric;

typedef struct HaoMetricRegistry {
    JSContext *ctx;
    HaoMetric entries[256];
    uint32_t count;
    struct HaoMetricRegistry *next;
} HaoMetricRegistry;

static _Atomic uint64_t resident_peak_bytes;
static _Atomic uint64_t physical_footprint_peak_bytes;
static pthread_mutex_t runtimes_mutex = PTHREAD_MUTEX_INITIALIZER;
static HaoTelemetry *runtimes;
static HaoMetricRegistry *registries;

static uint64_t update_peak(_Atomic uint64_t *peak, uint64_t value) {
    uint64_t current = atomic_load_explicit(peak, memory_order_relaxed);
    while (value > current && !atomic_compare_exchange_weak_explicit(
            peak, &current, value, memory_order_relaxed, memory_order_relaxed)) {}
    return atomic_load_explicit(peak, memory_order_relaxed);
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

static char *copy_text(const unsigned char *text, size_t length) {
    if (!text && length) return NULL;
    char *copy = hao_alloc(length + 1);
    if (!copy) return NULL;
    if (length) memcpy(copy, text, length);
    copy[length] = 0;
    return copy;
}

static void free_attributes(HaoTraceAttribute *attributes, size_t count) {
    for (size_t i = 0; i < count; i++) {
        hao_free(attributes[i].key);
        hao_free(attributes[i].text);
        memset(&attributes[i], 0, sizeof(attributes[i]));
    }
}

static void free_trace_record(HaoTraceRecord *record) {
    if (!record) return;
    hao_free(record->name);
    hao_free(record->source_kind);
    hao_free(record->source);
    free_attributes(record->attributes, record->attribute_count);
    hao_free(record);
}

static void clear_trace_record(HaoTraceRecord *record) {
    if (!record) return;
    hao_free(record->name);
    hao_free(record->source_kind);
    hao_free(record->source);
    free_attributes(record->attributes, record->attribute_count);
    memset(record, 0, sizeof(*record));
}

static void free_span(HaoNativeSpan *span) {
    if (!span) return;
    free_trace_record(span->pending);
    hao_free(span->name);
    hao_free(span->source_kind);
    hao_free(span->source);
    hao_free(span);
}

static HaoTraceRecord *new_trace_record(int kind, const unsigned char *name, size_t name_len,
                                        int64_t timestamp, const char *source_kind,
                                        const char *source) {
    if (name_len > 96) return NULL;
    HaoTraceRecord *record = hao_calloc(1, sizeof(*record));
    if (!record) return NULL;
    record->kind = kind;
    record->timestamp = timestamp;
    record->name_len = name_len;
    record->name = copy_text(name, name_len);
    record->status = TRACE_STATUS_UNSET;
    const char *kind_text = source_kind ? source_kind : "native";
    const char *source_text = source ? source : "";
    record->source_kind_len = strlen(kind_text);
    record->source_len = strlen(source_text);
    record->source_kind = hao_strdup(kind_text);
    record->source = hao_strdup(source_text);
    if (!record->name || !record->source_kind || !record->source) {
        free_trace_record(record);
        return NULL;
    }
    return record;
}

static void ring_append_locked(HaoTelemetry *telemetry, HaoTraceRecord *record) {
    if (!telemetry->enabled || !telemetry->capacity || !record || record->invalid) {
        clear_trace_record(record);
        hao_free(record);
        return;
    }
    record->sequence = telemetry->next_sequence++;
    size_t slot;
    if (telemetry->record_count < telemetry->capacity) {
        slot = (telemetry->record_head + telemetry->record_count) % telemetry->capacity;
        telemetry->record_count++;
    } else {
        slot = telemetry->record_head;
        telemetry->record_head = (telemetry->record_head + 1) % telemetry->capacity;
        clear_trace_record(&telemetry->records[slot]);
    }
    telemetry->records[slot] = *record;
    memset(record, 0, sizeof(*record));
    hao_free(record);
}

static void ring_append(HaoTelemetry *telemetry, HaoTraceRecord *record) {
    if (!telemetry || !record) {
        free_trace_record(record);
        return;
    }
    pthread_mutex_lock(&telemetry->mutex);
    ring_append_locked(telemetry, record);
    pthread_mutex_unlock(&telemetry->mutex);
}

static uint64_t random_id(void) {
    uint64_t id = 0;
    if (uv_random(NULL, NULL, &id, sizeof(id), 0, NULL) != 0 || id == 0) return 0;
    return id;
}

static uint32_t allocate_id(uint32_t *next) {
    uint32_t result = *next;
    if (++(*next) == 0 || *next > 0x7fffffffu) *next = 1;
    return result;
}

static HaoNativeSpan *find_span_locked(HaoTelemetry *telemetry, uint32_t public_id) {
    for (HaoNativeSpan *span = telemetry->spans; span; span = span->next) {
        if (span->public_id == public_id) return span;
    }
    return NULL;
}

static bool span_is_active_locked(HaoTelemetry *telemetry, HaoNativeSpan *span) {
    for (HaoNativeSpan *candidate = telemetry->spans; candidate; candidate = candidate->next) {
        if (candidate == span) return true;
    }
    return false;
}

static void unlink_span_locked(HaoTelemetry *telemetry, HaoNativeSpan *span) {
    HaoNativeSpan **link = &telemetry->spans;
    while (*link && *link != span) link = &(*link)->next;
    if (*link) *link = span->next;
}

static HaoNativeSpan *start_span_locked(HaoTelemetry *telemetry,
                                        uint64_t parent_trace, uint64_t parent_span,
                                        int parent_sampled, int64_t timestamp,
                                        const unsigned char *name, size_t name_len,
                                        int span_kind, const char *source_kind,
                                        const char *source, HaoTraceRecord *start_record) {
    if (!telemetry || name_len > 96) return NULL;
    HaoNativeSpan *span = hao_calloc(1, sizeof(*span));
    if (!span) return NULL;
    span->telemetry = telemetry;
    span->public_id = allocate_id(&telemetry->next_span_id);
    span->span_id = random_id();
    span->trace_id = parent_span ? parent_trace : random_id();
    if (parent_span && !span->trace_id) span->trace_id = random_id();
    span->parent_id = parent_span;
    span->sampled = telemetry->enabled && parent_sampled != 0;
    span->span_kind = span_kind;
    span->name_len = name_len;
    span->name = copy_text(name, name_len);
    const char *kind_text = source_kind ? source_kind : "native";
    const char *source_text = source ? source : "";
    span->source_kind_len = strlen(kind_text);
    span->source_len = strlen(source_text);
    span->source_kind = hao_strdup(kind_text);
    span->source = hao_strdup(source_text);
    if (!span->span_id || !span->trace_id || !span->name ||
        !span->source_kind || !span->source) {
        free_span(span);
        return NULL;
    }
    if (start_record) {
        start_record->timestamp = timestamp;
        start_record->trace_id = span->trace_id;
        start_record->span_id = span->span_id;
        start_record->parent_id = parent_span;
        start_record->span_kind = span_kind;
    }
    span->next = telemetry->spans;
    telemetry->spans = span;
    return span;
}

uintptr_t hao_telemetry_open(uintptr_t runtime, size_t trace_capacity, int enabled) {
    if (!runtime) return 0;
    HaoTelemetry *telemetry = hao_calloc(1, sizeof(*telemetry));
    if (!telemetry) return 0;
    if (pthread_mutex_init(&telemetry->mutex, NULL) != 0) {
        hao_free(telemetry);
        return 0;
    }
    if (enabled && trace_capacity) {
        telemetry->records = hao_calloc(trace_capacity, sizeof(*telemetry->records));
        if (!telemetry->records) {
            pthread_mutex_destroy(&telemetry->mutex);
            hao_free(telemetry);
            return 0;
        }
    }
    telemetry->runtime = runtime;
    telemetry->capacity = trace_capacity;
    telemetry->enabled = enabled != 0;
    telemetry->next_sequence = 1;
    telemetry->next_span_id = 1;
    telemetry->next_scope_id = 1;
    pthread_mutex_lock(&runtimes_mutex);
    telemetry->next = runtimes;
    runtimes = telemetry;
    pthread_mutex_unlock(&runtimes_mutex);
    return (uintptr_t)telemetry;
}

void hao_telemetry_set_enabled(uintptr_t handle, int enabled) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry) return;
    HaoTraceRecord *records = NULL;
    if (enabled && telemetry->capacity && !telemetry->records) {
        records = hao_calloc(telemetry->capacity, sizeof(*records));
        if (!records) enabled = 0;
    }
    pthread_mutex_lock(&telemetry->mutex);
    if (records) telemetry->records = records;
    telemetry->enabled = enabled != 0;
    pthread_mutex_unlock(&telemetry->mutex);
}

void hao_telemetry_context_capture(uintptr_t handle, HaoTraceContext *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry) return;
    pthread_mutex_lock(&telemetry->mutex);
    *out = telemetry->current;
    pthread_mutex_unlock(&telemetry->mutex);
}

bool hao_telemetry_context_enter(uintptr_t handle, const HaoTraceContext *context,
                                 HaoTraceContext *previous) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry || !context) return false;
    pthread_mutex_lock(&telemetry->mutex);
    if (previous) *previous = telemetry->current;
    telemetry->current = *context;
    pthread_mutex_unlock(&telemetry->mutex);
    return true;
}

void hao_telemetry_context_restore(uintptr_t handle, const HaoTraceContext *context) {
    if (!context) return;
    hao_telemetry_context_enter(handle, context, NULL);
}

static bool scope_enter_context_locked(HaoTelemetry *telemetry,
                                       const HaoTraceContext *context, uint32_t *out) {
    HaoTraceScope *scope = hao_calloc(1, sizeof(*scope));
    if (!scope) return false;
    scope->public_id = allocate_id(&telemetry->next_scope_id);
    scope->previous = telemetry->current;
    telemetry->current = *context;
    scope->next = telemetry->scopes;
    telemetry->scopes = scope;
    *out = scope->public_id;
    return true;
}

static bool scope_enter_locked(HaoTelemetry *telemetry, HaoNativeSpan *span, uint32_t *out) {
    HaoTraceContext context = {
        .trace_id = span->trace_id,
        .span_id = span->span_id,
        .sampled = span->sampled ? 1 : 0
    };
    return scope_enter_context_locked(telemetry, &context, out);
}

static bool scope_exit_locked(HaoTelemetry *telemetry, uint32_t public_id) {
    HaoTraceScope **link = &telemetry->scopes;
    while (*link && (*link)->public_id != public_id) link = &(*link)->next;
    if (!*link) return false;
    HaoTraceScope *scope = *link;
    *link = scope->next;
    telemetry->current = scope->previous;
    hao_free(scope);
    return true;
}

uintptr_t hao_telemetry_scope_enter(uintptr_t handle, const HaoTraceContext *context) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry || !context) return 0;
    uint32_t scope = 0;
    pthread_mutex_lock(&telemetry->mutex);
    bool ok = scope_enter_context_locked(telemetry, context, &scope);
    pthread_mutex_unlock(&telemetry->mutex);
    return ok ? scope : 0;
}

bool hao_telemetry_scope_exit(uintptr_t handle, uintptr_t scope) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry || !scope) return false;
    pthread_mutex_lock(&telemetry->mutex);
    bool ok = scope_exit_locked(telemetry, (uint32_t)scope);
    pthread_mutex_unlock(&telemetry->mutex);
    return ok;
}

static void append_trace_attributes(HaoTraceRecord *record, const HaoTraceAttribute *attributes,
                                    size_t count) {
    if (!record || !attributes) return;
    for (size_t i = 0; i < count && record->attribute_count < 16; i++) {
        HaoTraceAttribute *target = &record->attributes[record->attribute_count++];
        target->key_len = attributes[i].key_len;
        target->key = copy_text((const unsigned char *)attributes[i].key, attributes[i].key_len);
        target->kind = attributes[i].kind;
        target->boolean = attributes[i].boolean;
        target->integer = attributes[i].integer;
        target->floating = attributes[i].floating;
        target->text_len = attributes[i].text_len;
        if (attributes[i].kind == ATTRIBUTE_TEXT)
            target->text = copy_text((const unsigned char *)attributes[i].text,
                                     attributes[i].text_len);
        if (!target->key || (target->kind == ATTRIBUTE_TEXT && !target->text))
            record->invalid = true;
    }
}

uintptr_t hao_telemetry_source_span_start(uintptr_t handle, uint64_t parent_trace,
                                          uint64_t parent_span, int parent_sampled,
                                          int64_t timestamp, const unsigned char *name,
                                          size_t name_len, int span_kind,
                                          const char *source_kind, const char *source) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry) return 0;
    HaoTraceRecord *start = new_trace_record(SPAN_START, name, name_len, timestamp,
                                             source_kind, source);
    if (!start) return 0;
    pthread_mutex_lock(&telemetry->mutex);
    HaoNativeSpan *span = start_span_locked(telemetry, parent_trace, parent_span,
                                            parent_sampled, timestamp, name, name_len,
                                            span_kind, source_kind, source, start);
    if (span && span->sampled) span->pending = start;
    else free_trace_record(start);
    pthread_mutex_unlock(&telemetry->mutex);
    return (uintptr_t)span;
}

uintptr_t hao_telemetry_span_start(uintptr_t handle, uint64_t parent_trace,
                                   uint64_t parent_span, int parent_sampled,
                                   int64_t timestamp, const unsigned char *name,
                                   size_t name_len, int span_kind) {
    HaoTelemetry *telemetry = telemetry_for(handle);
    if (!telemetry) return 0;
    return hao_telemetry_source_span_start((uintptr_t)telemetry, parent_trace, parent_span,
                                            parent_sampled, timestamp, name,
                                            name_len, span_kind, "cyna", "");
}

uint64_t hao_telemetry_span_trace(uintptr_t handle) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    return span ? span->trace_id : 0;
}

uint64_t hao_telemetry_span_id(uintptr_t handle) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    return span ? span->span_id : 0;
}

int hao_telemetry_span_sampled(uintptr_t handle) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    return span && span->sampled;
}

uintptr_t hao_telemetry_span_pending(uintptr_t handle) {
    return handle ? (uintptr_t)((HaoNativeSpan *)handle)->pending : 0;
}

uintptr_t hao_telemetry_event_start(uintptr_t handle, int64_t timestamp,
                                    const unsigned char *name, size_t name_len) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    if (!span || !span->sampled || name_len > 96) return 0;
    HaoTraceRecord *record = new_trace_record(SPAN_EVENT, name, name_len, timestamp,
                                               span->source_kind, span->source);
    if (!record) return 0;
    record->trace_id = span->trace_id;
    record->span_id = span->span_id;
    record->span_kind = span->span_kind;
    return (uintptr_t)record;
}

void hao_telemetry_attribute(uintptr_t record_handle, const unsigned char *key,
                             size_t key_len, int kind, int boolean, int64_t integer,
                             double floating, const unsigned char *text, size_t text_len) {
    HaoTraceRecord *record = (HaoTraceRecord *)record_handle;
    if (!record || record->invalid) return;
    if (record->attribute_count == 16 || key_len > 64 ||
        (kind == ATTRIBUTE_TEXT && text_len > 256) ||
        kind < ATTRIBUTE_BOOL || kind > ATTRIBUTE_TEXT ||
        (kind == ATTRIBUTE_FLOAT && !isfinite(floating))) {
        record->invalid = true;
        return;
    }
    HaoTraceAttribute *attribute = &record->attributes[record->attribute_count];
    attribute->key = copy_text(key, key_len);
    attribute->key_len = key_len;
    attribute->kind = kind;
    attribute->boolean = boolean;
    attribute->integer = integer;
    attribute->floating = floating;
    attribute->text_len = text_len;
    if (kind == ATTRIBUTE_TEXT) attribute->text = copy_text(text, text_len);
    if (!attribute->key || (kind == ATTRIBUTE_TEXT && !attribute->text)) {
        hao_free(attribute->key);
        hao_free(attribute->text);
        memset(attribute, 0, sizeof(*attribute));
        record->invalid = true;
        return;
    }
    record->attribute_count++;
}

void hao_telemetry_record_finish(uintptr_t handle, uintptr_t record_handle) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    HaoTraceRecord *record = (HaoTraceRecord *)record_handle;
    if (!span || !record) return;
    HaoTelemetry *telemetry = span->telemetry;
    pthread_mutex_lock(&telemetry->mutex);
    if (!span_is_active_locked(telemetry, span)) {
        pthread_mutex_unlock(&telemetry->mutex);
        free_trace_record(record);
        return;
    }
    if (span->pending == record) span->pending = NULL;
    if (record->invalid) span->sampled = false;
    ring_append_locked(telemetry, record);
    pthread_mutex_unlock(&telemetry->mutex);
}

void hao_telemetry_span_end(uintptr_t handle, int64_t timestamp, int status) {
    HaoNativeSpan *span = (HaoNativeSpan *)handle;
    if (!span) return;
    HaoTelemetry *telemetry = span->telemetry;
    HaoTraceRecord *end = NULL;
    if (span->sampled) {
        end = new_trace_record(SPAN_END, (const unsigned char *)span->name,
                               span->name_len, timestamp,
                               span->source_kind, span->source);
        if (end) {
            end->trace_id = span->trace_id;
            end->span_id = span->span_id;
            end->status = status;
            end->span_kind = span->span_kind;
        }
    }
    pthread_mutex_lock(&telemetry->mutex);
    if (!span_is_active_locked(telemetry, span)) {
        pthread_mutex_unlock(&telemetry->mutex);
        free_trace_record(end);
        return;
    }
    HaoTraceRecord *pending = span->pending;
    span->pending = NULL;
    unlink_span_locked(telemetry, span);
    if (pending) ring_append_locked(telemetry, pending);
    if (end) ring_append_locked(telemetry, end);
    pthread_mutex_unlock(&telemetry->mutex);
    hao_free(span->name);
    hao_free(span->source_kind);
    hao_free(span->source);
    hao_free(span);
}

/* JS-facing trace lifecycle. */
static HaoTelemetry *telemetry_for_context(JSContext *ctx) {
    return telemetry_for((uintptr_t)JS_GetContextOpaque(ctx));
}

static bool copy_js_attributes(JSContext *ctx, JSValueConst value,
                               HaoTraceAttribute attributes[16], size_t *out_count) {
    *out_count = 0;
    if (JS_IsUndefined(value) || JS_IsNull(value)) return true;
    if (!JS_IsArray(value)) {
        JS_ThrowTypeError(ctx, "invalid trace attributes");
        return false;
    }
    uint32_t length = 0;
    JSValue length_value = JS_GetPropertyStr(ctx, value, "length");
    int status = JS_ToUint32(ctx, &length, length_value);
    JS_FreeValue(ctx, length_value);
    if (status < 0) return false;
    if (length > 16) {
        JS_ThrowRangeError(ctx, "too many trace attributes");
        return false;
    }
    for (uint32_t i = 0; i < length; i++) {
        JSValue pair = JS_GetPropertyUint32(ctx, value, i);
        if (!JS_IsArray(pair)) {
            JS_FreeValue(ctx, pair);
            JS_ThrowTypeError(ctx, "invalid trace attributes");
            return false;
        }
        JSValue key_value = JS_GetPropertyUint32(ctx, pair, 0);
        JSValue item = JS_GetPropertyUint32(ctx, pair, 1);
        size_t key_len = 0;
        const char *key = JS_ToCStringLen(ctx, &key_len, key_value);
        if (!key || key_len > 64) {
            if (key) JS_FreeCString(ctx, key);
            JS_FreeValue(ctx, key_value);
            JS_FreeValue(ctx, item);
            JS_FreeValue(ctx, pair);
            JS_ThrowRangeError(ctx, key ? "trace attribute key too long" :
                                         "invalid trace attributes");
            return false;
        }
        HaoTraceAttribute *attribute = &attributes[i];
        attribute->key = copy_text((const unsigned char *)key, key_len);
        attribute->key_len = key_len;
        JS_FreeCString(ctx, key);
        if (JS_IsBool(item)) {
            attribute->kind = ATTRIBUTE_BOOL;
            attribute->boolean = JS_ToBool(ctx, item);
        } else if (JS_IsNumber(item)) {
            if (JS_ToFloat64(ctx, &attribute->floating, item) < 0 ||
                !isfinite(attribute->floating)) {
                JS_FreeValue(ctx, key_value);
                JS_FreeValue(ctx, item);
                JS_FreeValue(ctx, pair);
                free_attributes(attributes, i + 1);
                JS_ThrowTypeError(ctx, "invalid trace attribute value");
                return false;
            }
            attribute->kind = ATTRIBUTE_FLOAT;
        } else if (JS_IsString(item)) {
            size_t text_len = 0;
            const char *text = JS_ToCStringLen(ctx, &text_len, item);
            if (!text || text_len > 256) {
                if (text) JS_FreeCString(ctx, text);
                JS_FreeValue(ctx, key_value);
                JS_FreeValue(ctx, item);
                JS_FreeValue(ctx, pair);
                free_attributes(attributes, i + 1);
                JS_ThrowRangeError(ctx, text ? "trace attribute value too long" :
                                              "invalid trace attribute value");
                return false;
            }
            attribute->kind = ATTRIBUTE_TEXT;
            attribute->text_len = text_len;
            attribute->text = copy_text((const unsigned char *)text, text_len);
            JS_FreeCString(ctx, text);
        } else {
            JS_FreeValue(ctx, key_value);
            JS_FreeValue(ctx, item);
            JS_FreeValue(ctx, pair);
            free_attributes(attributes, i + 1);
            JS_ThrowTypeError(ctx, "invalid trace attribute value");
            return false;
        }
        JS_FreeValue(ctx, key_value);
        JS_FreeValue(ctx, item);
        JS_FreeValue(ctx, pair);
        if (!attribute->key || (attribute->kind == ATTRIBUTE_TEXT && !attribute->text)) {
            free_attributes(attributes, i + 1);
            JS_ThrowOutOfMemory(ctx);
            return false;
        }
    }
    *out_count = length;
    return true;
}

static JSValue trace_span_start_js(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 3)
        return JS_ThrowTypeError(ctx, "start trace span requires name, root, and attributes");
    size_t name_len = 0;
    const char *name = JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (!name) return JS_EXCEPTION;
    int root = JS_ToBool(ctx, argv[1]);
    const char *source = argc >= 4 && !JS_IsUndefined(argv[3]) ?
        JS_ToCString(ctx, argv[3]) : "";
    if (!source) {
        JS_FreeCString(ctx, name);
        return JS_EXCEPTION;
    }
    HaoTraceAttribute attributes[16];
    memset(attributes, 0, sizeof(attributes));
    size_t attribute_count = 0;
    if (name_len > 96) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, source);
        return JS_ThrowRangeError(ctx, "trace name too long");
    }
    if (!copy_js_attributes(ctx, argv[2], attributes, &attribute_count)) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, source);
        return JS_EXCEPTION;
    }
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    if (!telemetry) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, source);
        free_attributes(attributes, attribute_count);
        return JS_ThrowInternalError(ctx, "failed to start trace span");
    }
    int64_t timestamp = (int64_t)uv_hrtime();
    HaoTraceRecord *start = new_trace_record(SPAN_START, (const unsigned char *)name,
                                             name_len, timestamp, "javascript", source);
    if (!start) {
        JS_FreeCString(ctx, name);
        JS_FreeCString(ctx, source);
        free_attributes(attributes, attribute_count);
        return JS_ThrowInternalError(ctx, "failed to start trace span");
    }
    append_trace_attributes(start, attributes, attribute_count);
    free_attributes(attributes, attribute_count);
    pthread_mutex_lock(&telemetry->mutex);
    uint64_t parent_trace = root ? 0 : telemetry->current.trace_id;
    uint64_t parent_span = root ? 0 : telemetry->current.span_id;
    int parent_sampled = root || telemetry->current.span_id == 0 ?
        1 : telemetry->current.sampled;
    HaoNativeSpan *span = start_span_locked(telemetry, parent_trace, parent_span,
                                            parent_sampled, timestamp,
                                            (const unsigned char *)name, name_len, 0,
                                            "javascript", source, start);
    if (span && start->invalid) span->sampled = false;
    if (span && span->sampled) ring_append_locked(telemetry, start);
    else free_trace_record(start);
    uint32_t public_id = span ? span->public_id : 0;
    pthread_mutex_unlock(&telemetry->mutex);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, source);
    if (!span) return JS_ThrowInternalError(ctx, "failed to start trace span");
    return JS_NewUint32(ctx, public_id);
}

static bool js_trace_id(JSContext *ctx, JSValueConst value, const char *kind, uint32_t *out) {
    int32_t signed_id = 0;
    if (JS_ToInt32(ctx, &signed_id, value) < 0) return false;
    if (signed_id < 0) {
        JS_ThrowTypeError(ctx, "trace %s id must be a non-negative integer", kind);
        return false;
    }
    *out = (uint32_t)signed_id;
    return true;
}

static JSValue trace_enter_js(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id = 0;
    if (argc < 1 || !js_trace_id(ctx, argv[0], "span", &id)) return JS_EXCEPTION;
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    if (!telemetry) return JS_ThrowInternalError(ctx, "failed to enter trace span");
    pthread_mutex_lock(&telemetry->mutex);
    HaoNativeSpan *span = find_span_locked(telemetry, id);
    uint32_t scope = 0;
    bool ok = span && scope_enter_locked(telemetry, span, &scope);
    pthread_mutex_unlock(&telemetry->mutex);
    if (!ok) return JS_ThrowInternalError(ctx, "failed to enter trace span");
    return JS_NewUint32(ctx, scope);
}

static JSValue trace_exit_js(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id = 0;
    if (argc < 1 || !js_trace_id(ctx, argv[0], "scope", &id)) return JS_EXCEPTION;
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    if (!telemetry) return JS_ThrowInternalError(ctx, "failed to exit trace span");
    pthread_mutex_lock(&telemetry->mutex);
    bool ok = scope_exit_locked(telemetry, id);
    pthread_mutex_unlock(&telemetry->mutex);
    if (!ok) return JS_ThrowInternalError(ctx, "failed to exit trace span");
    return JS_UNDEFINED;
}

static JSValue trace_event_js(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id = 0;
    if (argc < 2 || !js_trace_id(ctx, argv[0], "span", &id)) return JS_EXCEPTION;
    size_t name_len = 0;
    const char *name = JS_ToCStringLen(ctx, &name_len, argv[1]);
    if (!name) return JS_EXCEPTION;
    if (!name_len || name_len > 96) {
        JS_FreeCString(ctx, name);
        return JS_ThrowRangeError(ctx, "invalid trace name");
    }
    HaoTraceAttribute attributes[16];
    memset(attributes, 0, sizeof(attributes));
    size_t attribute_count = 0;
    if (!copy_js_attributes(ctx, argc >= 3 ? argv[2] : JS_UNDEFINED,
                            attributes, &attribute_count)) {
        JS_FreeCString(ctx, name);
        return JS_EXCEPTION;
    }
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    if (!telemetry) {
        JS_FreeCString(ctx, name);
        free_attributes(attributes, attribute_count);
        return JS_ThrowInternalError(ctx, "unknown trace span");
    }
    bool found = false;
    pthread_mutex_lock(&telemetry->mutex);
    HaoNativeSpan *span = find_span_locked(telemetry, id);
    if (span) {
        found = true;
        HaoTraceRecord *record = new_trace_record(
            SPAN_EVENT, (const unsigned char *)name, name_len,
            (int64_t)uv_hrtime(), span->source_kind, span->source);
        if (record) {
            record->trace_id = span->trace_id;
            record->span_id = span->span_id;
            record->span_kind = span->span_kind;
            append_trace_attributes(record, attributes, attribute_count);
            ring_append_locked(telemetry, record);
        }
    }
    pthread_mutex_unlock(&telemetry->mutex);
    JS_FreeCString(ctx, name);
    free_attributes(attributes, attribute_count);
    if (!found) return JS_ThrowInternalError(ctx, "unknown trace span");
    return JS_UNDEFINED;
}

static JSValue trace_end_js(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id = 0;
    if (argc < 1 || !js_trace_id(ctx, argv[0], "span", &id)) return JS_EXCEPTION;
    int status = TRACE_STATUS_OK;
    if (argc >= 2) {
        const char *text = JS_ToCString(ctx, argv[1]);
        if (!text) return JS_EXCEPTION;
        status = strcmp(text, "err") == 0 ? TRACE_STATUS_ERR :
                 strcmp(text, "unset") == 0 ? TRACE_STATUS_UNSET : TRACE_STATUS_OK;
        JS_FreeCString(ctx, text);
    }
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    if (!telemetry) return JS_ThrowInternalError(ctx, "failed to end trace span");
    HaoTraceRecord *end = NULL;
    pthread_mutex_lock(&telemetry->mutex);
    HaoNativeSpan *span = find_span_locked(telemetry, id);
    if (span && span->sampled) {
        end = new_trace_record(SPAN_END, (const unsigned char *)span->name, span->name_len,
                               (int64_t)uv_hrtime(), span->source_kind, span->source);
        if (end) {
            end->trace_id = span->trace_id;
            end->span_id = span->span_id;
            end->status = status;
            end->span_kind = span->span_kind;
            ring_append_locked(telemetry, end);
        }
    }
    if (span) unlink_span_locked(telemetry, span);
    pthread_mutex_unlock(&telemetry->mutex);
    if (!span) return JS_ThrowInternalError(ctx, "failed to end trace span");
    hao_free(span->name);
    hao_free(span->source_kind);
    hao_free(span->source);
    hao_free(span);
    return JS_UNDEFINED;
}

static void hex64(uint64_t value, char out[17]) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 15; i >= 0; i--) {
        out[i] = hex[value & 15];
        value >>= 4;
    }
    out[16] = 0;
}

static JSValue trace_record_js(JSContext *ctx, const HaoTraceRecord *record) {
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
    char trace[33] = "0000000000000000";
    char span[17];
    char parent[17];
    hex64(record->trace_id, trace + 16);
    hex64(record->span_id, span);
    hex64(record->parent_id, parent);
    const char *kind = record->kind == SPAN_START ? "span_start" :
                       record->kind == SPAN_EVENT ? "event" : "span_end";
    JS_SetPropertyStr(ctx, result, "sequence", JS_NewInt64(ctx, (int64_t)record->sequence));
    JS_SetPropertyStr(ctx, result, "kind", JS_NewString(ctx, kind));
    JS_SetPropertyStr(ctx, result, "timestamp_ns",
                      JS_NewFloat64(ctx, (double)record->timestamp));
    JS_SetPropertyStr(ctx, result, "trace_id", JS_NewString(ctx, trace));
    JS_SetPropertyStr(ctx, result, "span_id", JS_NewString(ctx, span));
    JS_SetPropertyStr(ctx, result, "parent_span_id", JS_NewString(ctx, parent));
    JS_SetPropertyStr(ctx, result, "name",
                      JS_NewStringLen(ctx, record->name, record->name_len));
    JS_SetPropertyStr(ctx, result, "status", JS_NewString(ctx,
        record->status == TRACE_STATUS_OK ? "ok" :
        record->status == TRACE_STATUS_ERR ? "err" : "unset"));
    JS_SetPropertyStr(ctx, result, "source_kind",
                      JS_NewStringLen(ctx, record->source_kind, record->source_kind_len));
    JS_SetPropertyStr(ctx, result, "source",
                      JS_NewStringLen(ctx, record->source, record->source_len));
    JSValue attributes = JS_NewObject(ctx);
    for (size_t i = 0; i < record->attribute_count; i++) {
        const HaoTraceAttribute *attribute = &record->attributes[i];
        JSValue value = attribute->kind == ATTRIBUTE_BOOL ? JS_NewBool(ctx, attribute->boolean) :
                        attribute->kind == ATTRIBUTE_INT ? JS_NewInt64(ctx, attribute->integer) :
                        attribute->kind == ATTRIBUTE_FLOAT ?
                            JS_NewFloat64(ctx, attribute->floating) :
                            JS_NewStringLen(ctx, attribute->text, attribute->text_len);
        JSAtom key = JS_NewAtomLen(ctx, attribute->key, attribute->key_len);
        JS_SetProperty(ctx, attributes, key, value);
        JS_FreeAtom(ctx, key);
    }
    JS_SetPropertyStr(ctx, result, "attributes", attributes);
    return result;
}

static bool optional_filter_text(JSContext *ctx, JSValueConst filter, const char *key,
                                 char **out) {
    *out = NULL;
    JSValue value = JS_GetPropertyStr(ctx, filter, key);
    if (JS_IsUndefined(value) || JS_IsNull(value)) {
        JS_FreeValue(ctx, value);
        return true;
    }
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, value);
    JS_FreeValue(ctx, value);
    if (!text) return false;
    *out = copy_text((const unsigned char *)text, length);
    JS_FreeCString(ctx, text);
    return *out != NULL;
}

static bool record_matches_filter(const HaoTraceRecord *record, const char *source_kind,
                                  const char *source, const char *trace_id,
                                  const char *span_id, const char *name,
                                  const char *status, double since_ns, bool has_since_ns) {
    char trace[33] = "0000000000000000";
    char span[17];
    hex64(record->trace_id, trace + 16);
    hex64(record->span_id, span);
    if (source_kind && strcmp(record->source_kind, source_kind)) return false;
    if (source && strcmp(record->source, source)) return false;
    if (trace_id && strcmp(trace, trace_id)) return false;
    if (span_id && strcmp(span, span_id)) return false;
    if (name && strcmp(record->name, name)) return false;
    if (status && strcmp(record->status == TRACE_STATUS_OK ? "ok" :
                         record->status == TRACE_STATUS_ERR ? "err" : "unset", status))
        return false;
    return !has_since_ns || (double)record->timestamp >= since_ns;
}

static JSValue trace_snapshot_js(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t since = 0;
    int32_t limit = 100;
    if (argc >= 1 && JS_ToInt32(ctx, &since, argv[0]) < 0) return JS_EXCEPTION;
    if (argc >= 2 && JS_ToInt32(ctx, &limit, argv[1]) < 0) return JS_EXCEPTION;
    if (since < 0 || limit < 1)
        return JS_ThrowRangeError(ctx, "invalid trace cursor or limit");
    JSValueConst filter = argc >= 3 ? argv[2] : JS_UNDEFINED;
    if (!JS_IsUndefined(filter) && !JS_IsNull(filter) && !JS_IsObject(filter))
        return JS_ThrowTypeError(ctx, "invalid trace filter");
    char *source_kind = NULL, *source = NULL, *trace_id = NULL, *span_id = NULL;
    char *name = NULL, *status = NULL;
    bool has_since_ns = false;
    double since_ns = 0;
    if (JS_IsObject(filter)) {
        if (!optional_filter_text(ctx, filter, "source_kind", &source_kind) ||
            !optional_filter_text(ctx, filter, "source", &source) ||
            !optional_filter_text(ctx, filter, "trace_id", &trace_id) ||
            !optional_filter_text(ctx, filter, "span_id", &span_id) ||
            !optional_filter_text(ctx, filter, "name", &name) ||
            !optional_filter_text(ctx, filter, "status", &status)) goto fail;
        JSValue since_value = JS_GetPropertyStr(ctx, filter, "since_ns");
        if (!JS_IsUndefined(since_value) && !JS_IsNull(since_value)) {
            if (JS_ToFloat64(ctx, &since_ns, since_value) < 0 || !isfinite(since_ns) ||
                since_ns < 0) {
                JS_FreeValue(ctx, since_value);
                goto fail;
            }
            has_since_ns = true;
        }
        JS_FreeValue(ctx, since_value);
    }
    HaoTelemetry *telemetry = telemetry_for_context(ctx);
    JSValue result = JS_NewObject(ctx);
    JSValue records = JS_NewArray(ctx);
    if (JS_IsException(result) || JS_IsException(records)) {
        JS_FreeValue(ctx, result);
        JS_FreeValue(ctx, records);
        goto fail;
    }
    uint64_t latest = 0, next_cursor = (uint64_t)since, first = 0;
    uint32_t output_count = 0;
    if (telemetry) {
        pthread_mutex_lock(&telemetry->mutex);
        latest = telemetry->next_sequence - 1;
        if (telemetry->record_count)
            first = telemetry->records[telemetry->record_head].sequence;
        if ((uint64_t)since < latest) {
            size_t maximum = (size_t)limit < telemetry->capacity ?
                (size_t)limit : telemetry->capacity;
            for (size_t i = 0;
                 i < telemetry->record_count && output_count < maximum; i++) {
                size_t slot = (telemetry->record_head + i) % telemetry->capacity;
                HaoTraceRecord *record = &telemetry->records[slot];
                if (record->sequence <= (uint64_t)since) continue;
                next_cursor = record->sequence;
                if (!record_matches_filter(record, source_kind, source, trace_id, span_id,
                                           name, status, since_ns, has_since_ns)) continue;
                JS_SetPropertyUint32(ctx, records, output_count++,
                                     trace_record_js(ctx, record));
            }
        }
        pthread_mutex_unlock(&telemetry->mutex);
    }
    bool missed = first && since != 0 && first > (uint64_t)since + 1;
    JS_SetPropertyStr(ctx, result, "next_cursor", JS_NewInt64(ctx, (int64_t)next_cursor));
    JS_SetPropertyStr(ctx, result, "missed", JS_NewBool(ctx, missed));
    JS_SetPropertyStr(ctx, result, "records", records);
    hao_free(source_kind); hao_free(source); hao_free(trace_id);
    hao_free(span_id); hao_free(name); hao_free(status);
    return result;

fail:
    hao_free(source_kind); hao_free(source); hao_free(trace_id);
    hao_free(span_id); hao_free(name); hao_free(status);
    return JS_EXCEPTION;
}

/* Metric and memory views. */
static HaoMetricRegistry *registry_for(JSContext *ctx, int create) {
    for (HaoMetricRegistry *registry = registries; registry; registry = registry->next)
        if (registry->ctx == ctx) return registry;
    if (!create) return NULL;
    HaoMetricRegistry *registry = hao_calloc(1, sizeof(*registry));
    if (!registry) return NULL;
    registry->ctx = ctx;
    registry->next = registries;
    registries = registry;
    return registry;
}

int hao_metric_register(JSContext *ctx, const JsMetricDefinition *definition, uint32_t *out) {
    if (!definition || !out ||
        !hao_metric_definition_valid((const unsigned char *)definition->scope,
            (const unsigned char *)definition->name, definition->kind,
            (const unsigned char *)definition->unit)) return -1;
    const char *unit = definition->unit ? definition->unit : "";
    HaoMetricRegistry *registry = registry_for(ctx, 1);
    if (!registry) return -1;
    for (uint32_t i = 0; i < registry->count; i++) {
        HaoMetric *metric = &registry->entries[i];
        if (!strcmp(metric->scope, definition->scope) &&
            !strcmp(metric->name, definition->name)) {
            if (metric->kind != definition->kind || strcmp(metric->unit, unit)) return -1;
            *out = i;
            return 0;
        }
    }
    if (registry->count == 256) return -1;
    HaoMetric *metric = &registry->entries[registry->count];
    metric->scope = hao_strdup(definition->scope);
    metric->name = hao_strdup(definition->name);
    metric->unit = hao_strdup(unit);
    if (!metric->scope || !metric->name || !metric->unit) {
        hao_free(metric->scope);
        hao_free(metric->name);
        hao_free(metric->unit);
        memset(metric, 0, sizeof(*metric));
        return -1;
    }
    metric->kind = definition->kind;
    *out = registry->count++;
    return 0;
}

static HaoMetric *metric_for(JSContext *ctx, uint32_t id) {
    HaoMetricRegistry *registry = registry_for(ctx, 0);
    return registry && id < registry->count ? &registry->entries[id] : NULL;
}

int hao_metric_add(JSContext *ctx, uint32_t id, double delta) {
    HaoMetric *metric = metric_for(ctx, id);
    if (!metric || !hao_metric_can_add(metric->kind, delta)) return -1;
    metric->value += delta;
    return 0;
}

int hao_metric_set(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *metric = metric_for(ctx, id);
    if (!metric || !hao_metric_can_set(metric->kind, value)) return -1;
    metric->value = value;
    return 0;
}

int hao_metric_observe(JSContext *ctx, uint32_t id, double value) {
    HaoMetric *metric = metric_for(ctx, id);
    if (!metric || !hao_metric_can_observe(metric->kind)) return -1;
    if (!metric->count) {
        metric->min = value;
        metric->max = value;
    } else {
        metric->min = fmin(metric->min, value);
        metric->max = fmax(metric->max, value);
    }
    metric->count++;
    metric->sum += value;
    return 0;
}

int hao_metric_value(JSContext *ctx, uint32_t id, double *out) {
    HaoMetric *metric = metric_for(ctx, id);
    if (!metric || !out) return -1;
    *out = metric->kind == JS_METRIC_HISTOGRAM ?
        (double)metric->count : metric->value;
    return 0;
}

static void clear_registry(HaoMetricRegistry *registry) {
    for (uint32_t i = 0; i < registry->count; i++) {
        hao_free(registry->entries[i].scope);
        hao_free(registry->entries[i].name);
        hao_free(registry->entries[i].unit);
        memset(&registry->entries[i], 0, sizeof(registry->entries[i]));
    }
    registry->count = 0;
}

void hao_metric_cleanup(JSContext *ctx) {
    HaoMetricRegistry **link = &registries;
    while (*link) {
        HaoMetricRegistry *registry = *link;
        if (registry->ctx != ctx) {
            link = &registry->next;
            continue;
        }
        *link = registry->next;
        clear_registry(registry);
        hao_free(registry);
    }
}

void hao_telemetry_metric(uintptr_t handle, const unsigned char *scope, size_t scope_len,
                          const unsigned char *name, size_t name_len, int kind, int unit,
                          int64_t value, int set) {
    if (!handle || !scope_len || !name_len || scope_len > 255 || name_len > 255) return;
    HaoTelemetry *telemetry = telemetry_for(handle);
    if (!telemetry) return;
    HaoTraceRecord *item = hao_calloc(1, sizeof(*item));
    if (!item) return;
    item->kind = set ? METRIC_SET : METRIC_ADD;
    item->name = copy_text(name, name_len);
    item->name_len = name_len;
    item->source_kind = copy_text(scope, scope_len);
    item->source_kind_len = scope_len;
    item->source = hao_strdup("");
    item->span_kind = kind;
    item->status = unit;
    item->timestamp = value;
    if (!item->name || !item->source_kind || !item->source) {
        free_trace_record(item);
        return;
    }
    pthread_mutex_lock(&telemetry->mutex);
    if (telemetry->metric_tail) telemetry->metric_tail->next = item;
    else telemetry->metric_head = item;
    telemetry->metric_tail = item;
    pthread_mutex_unlock(&telemetry->mutex);
}

static JSValue metric_register_js(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsObject(argv[0]))
        return JS_ThrowTypeError(ctx, "registerMetric requires a definition object");
    JSValue scope = JS_GetPropertyStr(ctx, argv[0], "scope");
    JSValue name = JS_GetPropertyStr(ctx, argv[0], "name");
    JSValue kind = JS_GetPropertyStr(ctx, argv[0], "kind");
    JSValue unit = JS_GetPropertyStr(ctx, argv[0], "unit");
    size_t scope_len = 0, name_len = 0, kind_len = 0, unit_len = 0;
    const char *scope_text = !JS_IsNull(scope) && !JS_IsUndefined(scope) ?
        JS_ToCStringLen(ctx, &scope_len, scope) : NULL;
    const char *name_text = !JS_IsNull(name) && !JS_IsUndefined(name) ?
        JS_ToCStringLen(ctx, &name_len, name) : NULL;
    const char *kind_text = !JS_IsNull(kind) && !JS_IsUndefined(kind) ?
        JS_ToCStringLen(ctx, &kind_len, kind) : NULL;
    const char *unit_text = !JS_IsNull(unit) && !JS_IsUndefined(unit) ?
        JS_ToCStringLen(ctx, &unit_len, unit) : NULL;
    uint32_t metric_kind = kind_text &&
        hao_metric_text_valid((const unsigned char *)kind_text, kind_len, 1) ?
        hao_metric_kind((const unsigned char *)kind_text) : 0;
    JsMetricDefinition definition = {scope_text, name_text, metric_kind, unit_text};
    uint32_t id = 0;
    bool valid = scope_text && name_text && kind_text && metric_kind &&
        hao_metric_text_valid((const unsigned char *)scope_text, scope_len, 1) &&
        hao_metric_text_valid((const unsigned char *)name_text, name_len, 1) &&
        (!unit_text || hao_metric_text_valid((const unsigned char *)unit_text, unit_len, 0));
    int result = valid && hao_metric_register(ctx, &definition, &id) == 0;
    const char *error = !scope_text ? "metric scope must be a string" :
        !name_text ? "metric name must be a string" :
        !kind_text ? "metric kind must be a string" :
        !metric_kind ? "metric kind must be counter, gauge, or histogram" :
        "failed to register metric";
    if (scope_text) JS_FreeCString(ctx, scope_text);
    if (name_text) JS_FreeCString(ctx, name_text);
    if (kind_text) JS_FreeCString(ctx, kind_text);
    if (unit_text) JS_FreeCString(ctx, unit_text);
    JS_FreeValue(ctx, scope); JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, kind); JS_FreeValue(ctx, unit);
    if (result) return JS_NewUint32(ctx, id);
    if (!scope_text || !name_text || !kind_text || !metric_kind)
        return JS_ThrowTypeError(ctx, "%s", error);
    return JS_ThrowInternalError(ctx, "%s", error);
}

static JSValue metric_action_js(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv, int magic) {
    (void)this_val;
    int32_t signed_id = 0;
    double value = 0;
    const char *action = magic == 0 ? "add" : magic == 1 ? "set" : "observe";
    if (argc < 2)
        return JS_ThrowTypeError(ctx, "%sMetric requires id and %s", action,
                                 magic == 0 ? "delta" : "value");
    if (JS_ToInt32(ctx, &signed_id, argv[0]) < 0 || signed_id < 0) {
        JSValue error = JS_GetException(ctx);
        JS_FreeValue(ctx, error);
        return JS_ThrowTypeError(ctx, "metric id must be a non-negative integer");
    }
    if (JS_ToFloat64(ctx, &value, argv[1]) < 0) {
        JSValue error = JS_GetException(ctx);
        JS_FreeValue(ctx, error);
        return JS_ThrowTypeError(ctx, magic == 0 ? "metric delta must be a number" :
                                                 "metric value must be a number");
    }
    uint32_t id = (uint32_t)signed_id;
    int status = magic == 0 ? hao_metric_add(ctx, id, value) :
                 magic == 1 ? hao_metric_set(ctx, id, value) :
                 hao_metric_observe(ctx, id, value);
    return status == 0 ? JS_UNDEFINED :
        JS_ThrowInternalError(ctx, "failed to %s metric", action);
}

static JSValue metric_value_js(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    uint32_t id = 0;
    double value = 0;
    if (argc < 1) return JS_ThrowTypeError(ctx, "metric id required");
    if (JS_ToUint32(ctx, &id, argv[0]) < 0) return JS_EXCEPTION;
    return hao_metric_value(ctx, id, &value) == 0 ?
        JS_NewFloat64(ctx, value) : JS_ThrowTypeError(ctx, "invalid metric id");
}

static void drain_metrics(JSContext *ctx) {
    HaoTelemetry *telemetry = telemetry_for((uintptr_t)JS_GetContextOpaque(ctx));
    if (!telemetry) return;
    pthread_mutex_lock(&telemetry->mutex);
    HaoTraceRecord *items = telemetry->metric_head;
    telemetry->metric_head = telemetry->metric_tail = NULL;
    pthread_mutex_unlock(&telemetry->mutex);
    while (items) {
        HaoTraceRecord *item = items;
        items = item->next;
        const char *units[] = {"count", "bytes", "nanoseconds"};
        JsMetricDefinition definition = {
            item->source_kind,
            item->name,
            item->span_kind == 0 ? JS_METRIC_COUNTER : JS_METRIC_GAUGE,
            units[item->status < 0 || item->status > 2 ? 0 : item->status]
        };
        uint32_t id = 0;
        if (hao_metric_register(ctx, &definition, &id) == 0) {
            if (item->kind == METRIC_ADD)
                hao_metric_add(ctx, id, (double)item->timestamp);
            else hao_metric_set(ctx, id, (double)item->timestamp);
        }
        free_trace_record(item);
    }
}

static JSValue drain_metrics_js(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    drain_metrics(ctx);
    return JS_UNDEFINED;
}

static JSValue metric_snapshot_js(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    drain_metrics(ctx);
    HaoMetricRegistry *registry = registry_for(ctx, 0);
    JSValue array = JS_NewArray(ctx);
    if (JS_IsException(array)) return array;
    for (uint32_t i = 0; registry && i < registry->count; i++) {
        HaoMetric *metric = &registry->entries[i];
        JSValue item = JS_NewObject(ctx);
        JS_SetPropertyStr(ctx, item, "id", JS_NewUint32(ctx, i));
        JS_SetPropertyStr(ctx, item, "scope", JS_NewString(ctx, metric->scope));
        JS_SetPropertyStr(ctx, item, "name", JS_NewString(ctx, metric->name));
        JS_SetPropertyStr(ctx, item, "kind", JS_NewString(ctx, metric->kind == 1 ?
            "counter" : metric->kind == 2 ? "gauge" : "histogram"));
        JS_SetPropertyStr(ctx, item, "unit", JS_NewString(ctx, metric->unit));
        JS_SetPropertyStr(ctx, item, "value", JS_NewFloat64(ctx, metric->value));
        JS_SetPropertyStr(ctx, item, "count", JS_NewFloat64(ctx, (double)metric->count));
        JS_SetPropertyStr(ctx, item, "sum", JS_NewFloat64(ctx, metric->sum));
        JS_SetPropertyStr(ctx, item, "min", JS_NewFloat64(ctx, metric->min));
        JS_SetPropertyStr(ctx, item, "max", JS_NewFloat64(ctx, metric->max));
        JS_SetPropertyUint32(ctx, array, i, item);
    }
    return array;
}

static JSValue metric_clear_js(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    drain_metrics(ctx);
    HaoMetricRegistry *registry = registry_for(ctx, 0);
    if (registry) clear_registry(registry);
    return JS_UNDEFINED;
}

static JSValue memory_snapshot(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(JS_GetRuntime(ctx), &usage);
    HaoAllocatorStats allocator = hao_allocator_stats();
    uint64_t resident_bytes = 0, physical_footprint_bytes = 0;
    hao_process_memory_snapshot(&resident_bytes, &physical_footprint_bytes);
    uint64_t resident_peak = update_peak(&resident_peak_bytes, resident_bytes);
    uint64_t physical_peak = update_peak(&physical_footprint_peak_bytes,
                                         physical_footprint_bytes);
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
    GAUGE("physical_footprint_peak_bytes", physical_peak);
#undef GAUGE
    return result;
}

static JSValue monotonic_time_ns(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewFloat64(ctx, (double)uv_hrtime());
}

void hao_install_telemetry_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_monotonicNs",
                      JS_NewCFunction(ctx, monotonic_time_ns, "monotonicNs", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_memorySnapshot",
                      JS_NewCFunction(ctx, memory_snapshot, "memorySnapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_register",
                      JS_NewCFunction(ctx, metric_register_js, "register", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_add",
                      JS_NewCFunctionMagic(ctx, metric_action_js, "add", 2,
                                           JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_set",
                      JS_NewCFunctionMagic(ctx, metric_action_js, "set", 2,
                                           JS_CFUNC_generic_magic, 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_observe",
                      JS_NewCFunctionMagic(ctx, metric_action_js, "observe", 2,
                                           JS_CFUNC_generic_magic, 2));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_value",
                      JS_NewCFunction(ctx, metric_value_js, "value", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_snapshot",
                      JS_NewCFunction(ctx, metric_snapshot_js, "snapshot", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_clear",
                      JS_NewCFunction(ctx, metric_clear_js, "clear", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_drainMetrics",
                      JS_NewCFunction(ctx, drain_metrics_js, "drainMetrics", 0));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_startSpan",
                      JS_NewCFunction(ctx, trace_span_start_js, "startSpan", 3));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_enterSpan",
                      JS_NewCFunction(ctx, trace_enter_js, "enterSpan", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_exitSpan",
                      JS_NewCFunction(ctx, trace_exit_js, "exitSpan", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_addEvent",
                      JS_NewCFunction(ctx, trace_event_js, "addEvent", 2));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_endSpan",
                      JS_NewCFunction(ctx, trace_end_js, "endSpan", 1));
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_snapshotTraces",
                      JS_NewCFunction(ctx, trace_snapshot_js, "snapshotTraces", 2));
}

void hao_telemetry_close(uintptr_t handle) {
    HaoTelemetry *telemetry = (HaoTelemetry *)handle;
    if (!telemetry) return;
    pthread_mutex_lock(&runtimes_mutex);
    HaoTelemetry **runtime_link = &runtimes;
    while (*runtime_link && *runtime_link != telemetry)
        runtime_link = &(*runtime_link)->next;
    if (*runtime_link) *runtime_link = telemetry->next;
    pthread_mutex_unlock(&runtimes_mutex);

    pthread_mutex_lock(&telemetry->mutex);
    HaoTraceRecord *metrics = telemetry->metric_head;
    HaoNativeSpan *spans = telemetry->spans;
    HaoTraceScope *scopes = telemetry->scopes;
    telemetry->metric_head = telemetry->metric_tail = NULL;
    telemetry->spans = NULL;
    telemetry->scopes = NULL;
    pthread_mutex_unlock(&telemetry->mutex);

    while (metrics) {
        HaoTraceRecord *next = metrics->next;
        free_trace_record(metrics);
        metrics = next;
    }
    while (spans) {
        HaoNativeSpan *next = spans->next;
        free_span(spans);
        spans = next;
    }
    while (scopes) {
        HaoTraceScope *next = scopes->next;
        hao_free(scopes);
        scopes = next;
    }
    if (telemetry->records) {
        for (size_t i = 0; i < telemetry->capacity; i++)
            clear_trace_record(&telemetry->records[i]);
    }
    hao_free(telemetry->records);
    pthread_mutex_destroy(&telemetry->mutex);
    hao_free(telemetry);
}
