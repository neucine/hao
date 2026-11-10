#include "hao.h"
#include <stdio.h>
#include <string.h>

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
    if (hao_embed_install_std(runtime, NULL, 1) == 0) return 8;
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
    if (!status) status = hao_embed_register_module(runtime, (const unsigned char *)module_name,
        strlen(module_name), (const unsigned char *)module_source, strlen(module_source));
    if (!status) status = hao_embed_eval(runtime, (const unsigned char *)source,
        strlen(source), (const unsigned char *)filename, strlen(filename));
    if (!status) status = hao_embed_run_until_idle(runtime);
    hao_embed_free(runtime);
    return status;
}
