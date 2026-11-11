#ifndef HAO_EMBED_H
#define HAO_EMBED_H

#include <stddef.h>
#include <stdint.h>

#define HAO_EMBED_ABI_VERSION 2

#ifdef __cplusplus
extern "C" {
#endif

/* A runtime handle is owned by the caller and must be freed once. */
typedef uintptr_t HaoRuntimeHandle;

/* Check this before calling the runtime from a separately built host. */
uint32_t hao_embed_abi_version(void);

HaoRuntimeHandle hao_embed_new(void);
void hao_embed_free(HaoRuntimeHandle runtime);

/* Return zero on success. Source and names are copied before returning.
   A null byte pointer is valid only when its length is zero. Module specifiers
   must be nonempty and cannot contain a NUL byte. */
int hao_embed_eval(HaoRuntimeHandle runtime, const unsigned char *source,
                   size_t source_len, const unsigned char *filename, size_t filename_len);
int hao_embed_register_module(HaoRuntimeHandle runtime, const unsigned char *specifier,
                              size_t specifier_len, const unsigned char *source, size_t source_len);
int hao_embed_run_until_idle(HaoRuntimeHandle runtime);

/* Last operation error. Returns the full byte length, excluding
   the terminator. Copies at most capacity - 1 bytes and terminates when output
   and capacity are nonzero. A zero return means no error is stored. The message
   is replaced or cleared by the next operation. */
size_t hao_embed_last_error(HaoRuntimeHandle runtime, unsigned char *output,
                            size_t capacity);

/* Install the standard modules from the directory shipped with Hao. */
int hao_embed_install_std(HaoRuntimeHandle runtime, const unsigned char *directory,
                          size_t directory_len);

#ifdef __cplusplus
}
#endif
#endif
