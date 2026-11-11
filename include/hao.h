#ifndef HAO_EMBED_H
#define HAO_EMBED_H

#include <stddef.h>
#include <stdint.h>

#define HAO_EMBED_ABI_VERSION 5

#ifdef __cplusplus
extern "C" {
#endif

/* A runtime handle is owned by the caller and must be freed once. */
typedef uintptr_t HaoRuntimeHandle;
typedef void *(*HaoNativeModuleLoader)(void *context, const char *module_name);
typedef int (*HaoPackageInstall)(HaoRuntimeHandle runtime, void *userdata);
typedef void (*HaoPackageDeinit)(HaoRuntimeHandle runtime, void *userdata);

typedef struct HaoEmbedSourceModule {
    const unsigned char *specifier;
    size_t specifier_len;
    const unsigned char *source;
    size_t source_len;
} HaoEmbedSourceModule;

typedef struct HaoEmbedNativeModule {
    const unsigned char *specifier;
    size_t specifier_len;
    HaoNativeModuleLoader loader;
} HaoEmbedNativeModule;

typedef struct HaoEmbedPackage {
    const unsigned char *name;
    size_t name_len;
    const HaoEmbedSourceModule *sources;
    size_t source_count;
    const HaoEmbedNativeModule *native_modules;
    size_t native_count;
    HaoPackageInstall install;
    HaoPackageDeinit deinit;
    void *userdata;
} HaoEmbedPackage;

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
/* The callback receives the runtime's QuickJS context and creates a native
   module for module_name. The callback must remain valid until runtime free. */
int hao_embed_register_native_module(HaoRuntimeHandle runtime,
                                     const unsigned char *specifier, size_t specifier_len,
                                     HaoNativeModuleLoader loader);
/* Install runs before every evaluation. Deinit runs once when the runtime is
   freed, in reverse registration order. Names are copied on registration. */
int hao_embed_register_package_callbacks(HaoRuntimeHandle runtime,
                                         const unsigned char *name, size_t name_len,
                                         HaoPackageInstall install,
                                         HaoPackageDeinit deinit, void *userdata);
/* Registers all package members together. On failure no member is retained.
   Each specifier must be the package name or begin with name followed by ':'.
   The std: prefix belongs only to the std package. */
int hao_embed_register_package(HaoRuntimeHandle runtime, const HaoEmbedPackage *package);
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
