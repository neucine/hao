#ifndef HAO_TRANSPILER_H
#define HAO_TRANSPILER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *hao_transpile_types_for_path(const char *source, const char *source_path);
char *hao_transform_module(const char *source, const char *source_path, uint8_t isolated, const char *namespace_root);
char *hao_transpiler_last_error(void);
void hao_transpiler_free(char *text);

#ifdef __cplusplus
}
#endif
#endif
