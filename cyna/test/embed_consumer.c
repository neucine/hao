#include "hao.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (hao_embed_abi_version() != HAO_EMBED_ABI_VERSION) return 3;
    HaoRuntimeHandle runtime = hao_embed_new();
    if (!runtime) return 1;
    if (hao_embed_eval(runtime, NULL, 1, (const unsigned char *)"x", 1) == 0) return 4;
    if (hao_embed_eval(runtime, (const unsigned char *)"", 0, NULL, 1) == 0) return 5;
    if (hao_embed_register_module(runtime, NULL, 1, (const unsigned char *)"", 0) == 0) return 6;
    if (hao_embed_register_module(runtime, (const unsigned char *)"x", 1, NULL, 1) == 0) return 7;
    if (hao_embed_install_std(runtime, NULL, 1) == 0) return 8;
    const char *module_name = "demo:answer";
    const char *module_source = "export const answer: number = 42;";
    const char *source = "import { answer } from 'demo:answer'; console.log(answer);";
    const char *filename = "<embed-example>";
    int status = hao_embed_install_std(runtime, (const unsigned char *)argv[1], strlen(argv[1]));
    if (!status) status = hao_embed_register_module(runtime, (const unsigned char *)module_name,
        strlen(module_name), (const unsigned char *)module_source, strlen(module_source));
    if (!status) status = hao_embed_eval(runtime, (const unsigned char *)source,
        strlen(source), (const unsigned char *)filename, strlen(filename));
    if (!status) status = hao_embed_run_until_idle(runtime);
    hao_embed_free(runtime);
    return status;
}
