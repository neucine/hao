#include "hao.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>

extern int hao_embed_telemetry_probe(HaoRuntimeHandle runtime);
extern void hao_telemetry_metric(uintptr_t handle, const unsigned char *scope, size_t scope_len,
    const unsigned char *name, size_t name_len, int kind, int unit, int64_t value, int set);

static void *emit_worker_metric(void *opaque) {
    HaoRuntimeHandle runtime = *(HaoRuntimeHandle *)opaque;
    hao_telemetry_metric(runtime, (const unsigned char *)"cyna.worker", 11,
        (const unsigned char *)"runs", 4, 0, 0, 2, 0);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (hao_embed_abi_version() != HAO_EMBED_ABI_VERSION) return 3;
    HaoRuntimeHandle runtime = hao_embed_new();
    if (!runtime) return 1;
    if (hao_embed_eval(runtime, NULL, 1, (const unsigned char *)"x", 1) == 0) return 4;
    unsigned char error[128];
    size_t error_len = hao_embed_last_error(runtime, error, sizeof(error));
    if (error_len != strlen("Invalid byte buffer") || strcmp((const char *)error, "Invalid byte buffer")) return 12;
    if (hao_embed_eval(runtime, (const unsigned char *)"", 0, NULL, 1) == 0) return 5;
    if (hao_embed_register_module(runtime, NULL, 1, (const unsigned char *)"", 0) == 0) return 6;
    if (hao_embed_register_module(runtime, (const unsigned char *)"x", 1, NULL, 1) == 0) return 7;
    if (hao_embed_register_module(runtime, (const unsigned char *)"", 0, (const unsigned char *)"", 0) == 0) return 25;
    const unsigned char nul_name[] = { 'd', 'e', 'm', 'o', 0, ':', 'x' };
    if (hao_embed_register_module(runtime, nul_name, sizeof(nul_name), (const unsigned char *)"", 0) == 0) return 26;
    if (hao_embed_install_std(runtime, NULL, 1) == 0) return 8;
    if (hao_embed_install_std(runtime, (const unsigned char *)"/missing-hao-modules", 20) == 0) return 19;
    if (!hao_embed_last_error(runtime, error, sizeof(error)) ||
        strcmp((const char *)error, "Standard module installation failed")) return 20;
    HaoRuntimeHandle other = hao_embed_new();
    if (!other || other == runtime) return 9;
    const char *other_source = "export const answer = 7;";
    if (hao_embed_register_module(other, (const unsigned char *)"demo:answer", 11,
            (const unsigned char *)other_source, strlen(other_source)) != 0) return 10;
    if (hao_embed_last_error(other, error, sizeof(error)) != 0) return 17;
    hao_embed_free(other);
    if (hao_embed_eval(runtime, NULL, 0, (const unsigned char *)"<empty>", 7) != 0) return 11;
    if (hao_embed_last_error(runtime, error, sizeof(error)) != 0) return 13;
    const char *bad_source = "throw new Error('embed failure')";
    if (hao_embed_eval(runtime, (const unsigned char *)bad_source, strlen(bad_source),
            (const unsigned char *)"<bad>", 5) != 0) return 14;
    if (hao_embed_run_until_idle(runtime) == 0) return 16;
    error_len = hao_embed_last_error(runtime, error, sizeof(error));
    if (!error_len || !strstr((const char *)error, "embed failure")) return 15;
    unsigned char small[2] = { 0, 0 };
    if (hao_embed_last_error(runtime, small, sizeof(small)) != error_len ||
        small[0] != 'E' || small[1] != 0) return 18;
    const char *module_name = "demo:answer";
    const char *module_source = "export const answer: number = 42;";
    const char *source = "import { answer } from 'demo:answer'; console.log(answer);";
    const char *filename = "<embed-example>";
    int status = hao_embed_install_std(runtime, (const unsigned char *)argv[1], strlen(argv[1]));
    if (!status) status = hao_embed_telemetry_probe(runtime);
    pthread_t worker;
    if (!status && pthread_create(&worker, NULL, emit_worker_metric, &runtime) != 0) status = 23;
    if (!status && pthread_join(worker, NULL) != 0) status = 24;
    const char *telemetry_source =
        "import { metrics } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "const metric = metrics().find(item => item.scope === 'cyna.probe' && item.name === 'runs');"
        "const worker = metrics().find(item => item.scope === 'cyna.worker' && item.name === 'runs');"
        "const records = snapshotTraceRecordsNative().records.filter(item => item.name.startsWith('cyna.'));"
        "if (metric?.value !== 3 || worker?.value !== 2 || records.map(item => item.kind).join(',') !== 'span_start,event,span_end'"
        " || records[0].attributes.step !== 42 || records[1].attributes.step !== 42)"
        " throw new Error('Cyna telemetry backend mismatch');";
    if (!status) status = hao_embed_eval(runtime, (const unsigned char *)telemetry_source,
        strlen(telemetry_source), (const unsigned char *)"<telemetry-probe>", 17);
    if (!status) status = hao_embed_register_module(runtime, (const unsigned char *)module_name,
        strlen(module_name), (const unsigned char *)module_source, strlen(module_source));
    if (!status && hao_embed_register_module(runtime, (const unsigned char *)module_name,
        strlen(module_name), (const unsigned char *)module_source, strlen(module_source)) == 0) return 21;
    if (!status && (!hao_embed_last_error(runtime, error, sizeof(error)) ||
        strcmp((const char *)error, "Module registration failed"))) return 22;
    if (!status) status = hao_embed_eval(runtime, (const unsigned char *)source,
        strlen(source), (const unsigned char *)filename, strlen(filename));
    if (!status) status = hao_embed_run_until_idle(runtime);
    hao_embed_free(runtime);
    return status;
}
