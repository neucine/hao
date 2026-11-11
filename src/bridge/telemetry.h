#ifndef HAO_TELEMETRY_H
#define HAO_TELEMETRY_H

#include <stddef.h>
#include <stdint.h>
#include <quickjs.h>
#include "../../include/addon.h"

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
void hao_install_telemetry_interface(JSContext *ctx, JSValue global);
uintptr_t hao_telemetry_open(uintptr_t runtime);
void hao_telemetry_set_enabled(uintptr_t telemetry, int enabled);
void hao_telemetry_close(uintptr_t telemetry);

#endif
