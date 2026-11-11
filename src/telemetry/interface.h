#ifndef HAO_TELEMETRY_INTERFACE_H
#define HAO_TELEMETRY_INTERFACE_H

#include <stddef.h>
#include <stdint.h>

void hao_telemetry_metric(uintptr_t handle, const unsigned char *scope, size_t scope_len, const unsigned char *name, size_t name_len, int kind, int unit, int64_t value, int set);
uintptr_t hao_telemetry_span_start(uintptr_t handle, uint64_t parent_trace, uint64_t parent_span, int parent_sampled, int64_t timestamp, const unsigned char *name, size_t name_len, int span_kind);
uint64_t hao_telemetry_span_trace(uintptr_t handle);
uint64_t hao_telemetry_span_id(uintptr_t handle);
int hao_telemetry_span_sampled(uintptr_t handle);
uintptr_t hao_telemetry_span_pending(uintptr_t handle);
uintptr_t hao_telemetry_event_start(uintptr_t handle, int64_t timestamp, const unsigned char *name, size_t name_len);
void hao_telemetry_attribute(uintptr_t record, const unsigned char *key, size_t key_len, int kind, int boolean, int64_t integer, double floating, const unsigned char *text, size_t text_len);
void hao_telemetry_record_finish(uintptr_t handle, uintptr_t record);
void hao_telemetry_span_end(uintptr_t handle, int64_t timestamp, int status);

#endif
