#ifndef HAO_TELEMETRY_H
#define HAO_TELEMETRY_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <quickjs.h>
#include "../../include/addon.h"

typedef struct HaoTelemetry HaoTelemetry;
typedef struct HaoTraceContext {
    uint64_t trace_id;
    uint64_t span_id;
    int sampled;
} HaoTraceContext;

int hao_metric_text_valid(const unsigned char *text, size_t length, int required);
unsigned hao_metric_kind(const unsigned char *name);
int hao_metric_definition_valid(const unsigned char *scope, const unsigned char *name,
                                unsigned kind, const unsigned char *unit);
int hao_metric_can_add(unsigned kind, double delta);
int hao_metric_can_set(unsigned kind, double value);
int hao_metric_can_observe(unsigned kind);
int hao_metric_register(JSContext *ctx, const JsMetricDefinition *definition, uint32_t *id);
int hao_metric_add(JSContext *ctx, uint32_t id, double delta);
int hao_metric_set(JSContext *ctx, uint32_t id, double value);
int hao_metric_observe(JSContext *ctx, uint32_t id, double value);
int hao_metric_value(JSContext *ctx, uint32_t id, double *value);
void hao_metric_cleanup(JSContext *ctx);
void hao_install_telemetry_globals(JSContext *ctx, JSValue global);
uintptr_t hao_telemetry_open(uintptr_t runtime, size_t trace_capacity, int enabled);
void hao_telemetry_set_enabled(uintptr_t telemetry, int enabled);
void hao_telemetry_context_capture(uintptr_t telemetry, HaoTraceContext *out);
bool hao_telemetry_context_enter(uintptr_t telemetry, const HaoTraceContext *context,
                                 HaoTraceContext *previous);
void hao_telemetry_context_restore(uintptr_t telemetry, const HaoTraceContext *context);
uintptr_t hao_telemetry_scope_enter(uintptr_t telemetry, const HaoTraceContext *context);
bool hao_telemetry_scope_exit(uintptr_t telemetry, uintptr_t scope);
void hao_telemetry_metric(uintptr_t telemetry, const unsigned char *scope,
                          size_t scope_len, const unsigned char *name, size_t name_len,
                          int kind, int unit, int64_t value, int set);
uintptr_t hao_telemetry_span_start(uintptr_t telemetry, uint64_t parent_trace,
                                   uint64_t parent_span, int parent_sampled,
                                   int64_t timestamp, const unsigned char *name,
                                   size_t name_len, int span_kind);
uintptr_t hao_telemetry_source_span_start(uintptr_t telemetry, uint64_t parent_trace,
                                          uint64_t parent_span, int parent_sampled,
                                          int64_t timestamp, const unsigned char *name,
                                          size_t name_len, int span_kind,
                                          const char *source_kind, const char *source);
uint64_t hao_telemetry_span_trace(uintptr_t span);
uint64_t hao_telemetry_span_id(uintptr_t span);
int hao_telemetry_span_sampled(uintptr_t span);
uintptr_t hao_telemetry_span_pending(uintptr_t span);
uintptr_t hao_telemetry_event_start(uintptr_t span, int64_t timestamp,
                                    const unsigned char *name, size_t name_len);
void hao_telemetry_attribute(uintptr_t record, const unsigned char *key, size_t key_len,
                             int kind, int boolean, int64_t integer, double floating,
                             const unsigned char *text, size_t text_len);
void hao_telemetry_record_finish(uintptr_t span, uintptr_t record);
void hao_telemetry_span_end(uintptr_t span, int64_t timestamp, int status);
void hao_telemetry_close(uintptr_t telemetry);

#endif
