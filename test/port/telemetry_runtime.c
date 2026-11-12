#include "hao.h"

#include <stdio.h>
#include <string.h>

extern int hao_embed_telemetry_probe(HaoRuntimeHandle runtime);

static int evaluate(HaoRuntimeHandle runtime, const char *label, const char *source) {
    int status = hao_embed_eval(
        runtime,
        (const unsigned char *)source,
        strlen(source),
        (const unsigned char *)label,
        strlen(label)
    );
    if (status) {
        unsigned char error[512];
        size_t length = hao_embed_last_error(runtime, error, sizeof(error));
        size_t shown = length < sizeof(error) ? length : sizeof(error) - 1;
        error[shown] = 0;
        fprintf(stderr, "%s: %s\n", label, (char *)error);
    }
    return status;
}

static int install_std(HaoRuntimeHandle runtime, const char *directory) {
    return hao_embed_install_std(
        runtime,
        (const unsigned char *)directory,
        strlen(directory)
    );
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (hao_embed_abi_version() != HAO_EMBED_ABI_VERSION) return 3;

    HaoRuntimeHandle first = hao_embed_new();
    HaoRuntimeHandle second = hao_embed_new();
    if (!first || !second || first == second) return 4;
    if (install_std(first, argv[1]) != 0 ||
        install_std(second, argv[1]) != 0) return 5;

    const char *first_create =
        "import { counter, metrics, trace } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "counter({scope:'isolation',name:'events'}).add(2);"
        "trace('runtime-a', () => trace('runtime-a-child', () => {}));"
        "const records = snapshotTraceRecordsNative().records;"
        "const metric = metrics().find(item => item.scope === 'isolation');"
        "if (records[0]?.sequence !== 1 || !records.find(item => item.name === 'runtime-a-child'))"
        " throw Error('runtime A sequence mismatch');"
        "if (metric?.value !== 2) throw Error('runtime A metric mismatch');";
    const char *second_create =
        "import { counter, metrics, trace } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "counter({scope:'isolation',name:'events'}).add(5);"
        "trace('runtime-b', () => trace('runtime-b-child', () => {}));"
        "const records = snapshotTraceRecordsNative().records;"
        "const metric = metrics().find(item => item.scope === 'isolation');"
        "if (records[0]?.sequence !== 1 || !records.find(item => item.name === 'runtime-b-child'))"
        " throw Error('runtime B sequence mismatch');"
        "if (metric?.value !== 5) throw Error('runtime B metric mismatch');";
    if (evaluate(first, "<runtime-a-create>", first_create) != 0 ||
        evaluate(second, "<runtime-b-create>", second_create) != 0) return 6;

    if (hao_embed_telemetry_probe(first) != 0 ||
        hao_embed_telemetry_probe(second) != 0) return 7;

    const char *first_check =
        "import { metrics } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "const cyna = snapshotTraceRecordsNative(0, 100, {source_kind:'cyna'}).records;"
        "const names = cyna.map(item => item.name);"
        "if (cyna.length !== 3 || names[0] !== 'cyna.probe' || names[1] !== 'cyna.event')"
        " throw Error('runtime A Cyna trace mismatch');"
        "if (metrics().find(item => item.scope === 'isolation')?.value !== 2)"
        " throw Error('runtime A metric was contaminated');";
    const char *second_check =
        "import { metrics } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "const cyna = snapshotTraceRecordsNative(0, 100, {source_kind:'cyna'}).records;"
        "const names = cyna.map(item => item.name);"
        "if (cyna.length !== 3 || names[0] !== 'cyna.probe' || names[1] !== 'cyna.event')"
        " throw Error('runtime B Cyna trace mismatch');"
        "if (metrics().find(item => item.scope === 'isolation')?.value !== 5)"
        " throw Error('runtime B metric was contaminated');";
    if (evaluate(first, "<runtime-a-check>", first_check) != 0 ||
        evaluate(second, "<runtime-b-check>", second_check) != 0) return 8;

    const char *pending_second =
        "import { trace } from 'std:telemetry';"
        "trace('runtime-b-pending', () => new Promise(() => {}));"
        "setTimeout(() => trace('runtime-b-timer', () => {}), 100);";
    if (evaluate(second, "<runtime-b-pending>", pending_second) != 0) return 9;
    hao_embed_free(second);

    const char *first_after_close =
        "import { trace } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "trace('runtime-a-after-close', () => {});"
        "const records = snapshotTraceRecordsNative().records;"
        "if (records.some(item => item.name.startsWith('runtime-b')))"
        " throw Error('closed runtime contaminated runtime A');"
        "if (!records.find(item => item.name === 'runtime-a-after-close'))"
        " throw Error('runtime A stopped after runtime B closed');";
    if (evaluate(first, "<runtime-a-after-close>", first_after_close) != 0) return 10;

    HaoRuntimeHandle replacement = hao_embed_new();
    if (!replacement || install_std(replacement, argv[1]) != 0) return 11;
    const char *replacement_create =
        "import { trace } from 'std:telemetry';"
        "import { snapshotTraceRecordsNative } from 'std:telemetry/native';"
        "trace('runtime-replacement', () => {});"
        "if (snapshotTraceRecordsNative().records[0]?.sequence !== 1)"
        " throw Error('replacement runtime reused another sequence');";
    if (evaluate(replacement, "<runtime-replacement>", replacement_create) != 0) return 12;

    const char *pending_first =
        "import { trace } from 'std:telemetry';"
        "trace('runtime-a-shutdown', () => new Promise(() => {}));"
        "setTimeout(() => trace('runtime-a-timer', () => {}), 100);";
    if (evaluate(first, "<runtime-a-shutdown>", pending_first) != 0) return 13;
    hao_embed_free(first);
    hao_embed_free(replacement);
    return 0;
}
