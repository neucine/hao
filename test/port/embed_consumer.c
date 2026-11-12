#include "hao.h"
#include <quickjs.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>

extern int hao_embed_telemetry_probe(HaoRuntimeHandle runtime);
extern void hao_telemetry_metric(uintptr_t handle, const unsigned char *scope, size_t scope_len,
    const unsigned char *name, size_t name_len, int kind, int unit, int64_t value, int set);

static int init_native_module(JSContext *context, JSModuleDef *module) {
    return JS_SetModuleExport(context, module, "answer", JS_NewInt32(context, 17));
}

static void *load_native_module(void *opaque, const char *name) {
    JSContext *context = opaque;
    JSModuleDef *module = JS_NewCModule(context, name, init_native_module);
    if (module) JS_AddModuleExport(context, module, "answer");
    return module;
}

static char package_order[16];
static size_t package_order_len;
static int install_package(HaoRuntimeHandle runtime, void *userdata) {
    (void)runtime;
    package_order[package_order_len++] = *(char *)userdata;
    return 0;
}
static int fail_install_package(HaoRuntimeHandle runtime, void *userdata) {
    (void)runtime;
    (void)userdata;
    return 1;
}
static void deinit_package(HaoRuntimeHandle runtime, void *userdata) {
    (void)runtime;
    package_order[package_order_len++] = (char)(*(char *)userdata + ('a' - 'A'));
}

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
    if (hao_embed_register_native_module(other, (const unsigned char *)"demo:native", 11,
            load_native_module) != 0) return 27;
    if (hao_embed_register_native_module(other, (const unsigned char *)"demo:native", 11,
            load_native_module) == 0) return 28;
    if (hao_embed_register_native_module(other, (const unsigned char *)"demo:missing", 12,
            NULL) == 0) return 30;
    if (hao_embed_register_module(other, (const unsigned char *)"demo:native", 11,
            (const unsigned char *)"", 0) == 0) return 31;
    if (hao_embed_register_native_module(other, (const unsigned char *)"demo:answer", 11,
            load_native_module) == 0) return 32;
    const char *native_source = "import { answer } from 'demo:native'; if (answer !== 17) throw Error('native module mismatch');";
    if (hao_embed_eval(other, (const unsigned char *)native_source, strlen(native_source),
            (const unsigned char *)"<native>", 8) != 0) return 29;
    char *owned_name = strdup("demo:owned");
    char *owned_source = strdup("export const value = 23;");
    if (!owned_name || !owned_source) return 119;
    if (hao_embed_register_module(other, (const unsigned char *)owned_name, strlen(owned_name),
            (const unsigned char *)owned_source, strlen(owned_source)) != 0) return 120;
    memset(owned_name, 'x', strlen(owned_name));
    memset(owned_source, 'x', strlen(owned_source));
    free(owned_name);
    free(owned_source);
    const char *owned_eval = "import { value } from 'demo:owned'; if (value !== 23) throw Error('module copy failed');";
    if (hao_embed_eval(other, (const unsigned char *)owned_eval, strlen(owned_eval),
            (const unsigned char *)"<owned>", 7) != 0) return 121;
    const char *timer_source =
        "globalThis.__timerReady = false; setTimeout(() => { globalThis.__timerReady = true; }, 1);";
    const char *timer_check = "if (!globalThis.__timerReady) throw Error('timer did not fire');";
    if (hao_embed_eval(runtime, (const unsigned char *)timer_source, strlen(timer_source),
            (const unsigned char *)"<timers>", 8) != 0 ||
        hao_embed_eval(other, (const unsigned char *)timer_source, strlen(timer_source),
            (const unsigned char *)"<timers>", 8) != 0) return 123;
    if (hao_embed_run_until_idle(other) != 0 ||
        hao_embed_eval(other, (const unsigned char *)timer_check, strlen(timer_check),
            (const unsigned char *)"<timers>", 8) != 0 ||
        hao_embed_run_until_idle(runtime) != 0 ||
        hao_embed_eval(runtime, (const unsigned char *)timer_check, strlen(timer_check),
            (const unsigned char *)"<timers>", 8) != 0) return 124;
    const char *isolated_timer =
        "globalThis.__timerReady = false; globalThis.__timerId = setTimeout(() => { globalThis.__timerReady = true; }, 1);"
        "if (globalThis.__timerId !== 2) throw Error('timer ID was not local');";
    const char *cancel_local = "clearTimeout(globalThis.__timerId);";
    const char *cancel_check = "if (globalThis.__timerReady) throw Error('cancelled timer fired');";
    if (hao_embed_eval(runtime, (const unsigned char *)isolated_timer, strlen(isolated_timer),
            (const unsigned char *)"<timers>", 8) != 0 ||
        hao_embed_eval(other, (const unsigned char *)isolated_timer, strlen(isolated_timer),
            (const unsigned char *)"<timers>", 8) != 0 ||
        hao_embed_eval(runtime, (const unsigned char *)cancel_local, strlen(cancel_local),
            (const unsigned char *)"<timers>", 8) != 0) return 126;
    if (hao_embed_run_until_idle(runtime) != 0 ||
        hao_embed_eval(runtime, (const unsigned char *)cancel_check, strlen(cancel_check),
            (const unsigned char *)"<timers>", 8) != 0 ||
        hao_embed_run_until_idle(other) != 0 ||
        hao_embed_eval(other, (const unsigned char *)timer_check, strlen(timer_check),
            (const unsigned char *)"<timers>", 8) != 0) return 127;
    if (hao_embed_last_error(other, error, sizeof(error)) != 0) return 17;
    const char *pending_timer = "setTimeout(() => { throw Error('timer survived free'); }, 100);";
    if (hao_embed_eval(other, (const unsigned char *)pending_timer, strlen(pending_timer),
            (const unsigned char *)"<timers>", 8) != 0) return 125;
    hao_embed_free(other);
    HaoRuntimeHandle atomic_runtime = hao_embed_new();
    char *atomic_source = strdup("export const value = 5;");
    if (!atomic_source) return 122;
    HaoEmbedSourceModule atomic_sources[] = {
        { (const unsigned char *)"demo:source", 11,
          (const unsigned char *)atomic_source, strlen(atomic_source) },
    };
    HaoEmbedNativeModule atomic_native[] = {
        { (const unsigned char *)"demo:native", 11, load_native_module },
    };
    HaoEmbedPackage atomic_package = {
        .name = (const unsigned char *)"demo", .name_len = 4,
        .sources = atomic_sources, .source_count = 1,
        .native_modules = atomic_native, .native_count = 1,
    };
    if (!atomic_runtime || hao_embed_register_package(atomic_runtime, &atomic_package) != 0) return 44;
    if (hao_embed_register_package(atomic_runtime, &atomic_package) == 0) return 46;
    memset(atomic_source, 'x', strlen(atomic_source));
    free(atomic_source);
    const char *atomic_eval = "import { value } from 'demo:source'; import { answer } from 'demo:native'; if (value + answer !== 22) throw Error('package mismatch');";
    if (hao_embed_eval(atomic_runtime, (const unsigned char *)atomic_eval, strlen(atomic_eval),
            (const unsigned char *)"<atomic>", 8) != 0) return 45;
    HaoEmbedSourceModule wrong_sources[] = {
        { (const unsigned char *)"other:valid", 11, (const unsigned char *)"", 0 },
        { (const unsigned char *)"wrong:module", 12, (const unsigned char *)"", 0 },
    };
    HaoEmbedPackage wrong_package = {
        .name = (const unsigned char *)"other", .name_len = 5,
        .sources = wrong_sources, .source_count = 2,
    };
    if (hao_embed_register_package(atomic_runtime, &wrong_package) == 0) return 47;
    if (hao_embed_register_module(atomic_runtime, (const unsigned char *)"other:valid", 11,
            (const unsigned char *)"", 0) != 0) return 48;
    HaoEmbedSourceModule empty_source = {
        (const unsigned char *)"empty:module", 12, NULL, 0,
    };
    HaoEmbedPackage empty_package = {
        .name = (const unsigned char *)"empty", .name_len = 5,
        .sources = &empty_source, .source_count = 1,
    };
    if (hao_embed_register_package(atomic_runtime, &empty_package) != 0) return 49;
    hao_embed_free(atomic_runtime);
    HaoRuntimeHandle package_runtime = hao_embed_new();
    char alpha = 'A', beta = 'B';
    if (!package_runtime ||
        hao_embed_register_package_callbacks(package_runtime, (const unsigned char *)"alpha", 5,
            install_package, deinit_package, &alpha) != 0 ||
        hao_embed_register_package_callbacks(package_runtime, (const unsigned char *)"beta", 4,
            install_package, deinit_package, &beta) != 0) return 33;
    if (hao_embed_register_package_callbacks(package_runtime, (const unsigned char *)"alpha", 5,
            install_package, deinit_package, &alpha) == 0) return 34;
    if (hao_embed_eval(package_runtime, (const unsigned char *)"", 0,
            (const unsigned char *)"<packages>", 10) != 0) return 35;
    if (package_order_len != 2 || memcmp(package_order, "AB", 2)) return 36;
    if (hao_embed_eval(package_runtime, (const unsigned char *)"", 0,
            (const unsigned char *)"<packages-2>", 12) != 0) return 38;
    if (package_order_len != 4 || memcmp(package_order, "ABAB", 4)) return 39;
    hao_embed_free(package_runtime);
    if (package_order_len != 6 || memcmp(package_order, "ABABba", 6)) return 37;
    HaoRuntimeHandle failing_runtime = hao_embed_new();
    char gamma = 'C';
    if (!failing_runtime ||
        hao_embed_register_package_callbacks(failing_runtime, (const unsigned char *)"gamma", 5,
            fail_install_package, deinit_package, &gamma) != 0) return 40;
    if (hao_embed_eval(failing_runtime, (const unsigned char *)"", 0,
            (const unsigned char *)"<failure>", 9) == 0) return 41;
    if (!hao_embed_last_error(failing_runtime, error, sizeof(error)) ||
        strcmp((const char *)error, "Package installation failed")) return 42;
    hao_embed_free(failing_runtime);
    if (package_order_len != 7 || package_order[6] != 'c') return 43;
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
        "const cyna = snapshotTraceRecordsNative(0, 100, { source_kind: 'cyna' }).records;"
        "if (metric?.value !== 3 || worker?.value !== 2 || records.map(item => item.kind).join(',') !== 'span_start,event,span_end'"
        " || records[0].attributes.step !== 42 || records[1].attributes.step !== 42"
        " || cyna.length !== 3 || cyna.some(item => item.source_kind !== 'cyna'))"
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
