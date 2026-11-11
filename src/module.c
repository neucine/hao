#include "runtime_host.h"
#include "runtime_allocator.h"
#include "../include/hao.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char *hao_transpile_types_for_path(const char *source, const char *source_path);
extern char *hao_transpiler_last_error(void);
extern void hao_transpiler_free(char *text);
extern JSModuleDef *hao_load_addon(JSContext *ctx, const char *name);
extern int hao_resolve_package(const unsigned char *base, const unsigned char *specifier,
                               unsigned char *output, size_t capacity);

static HaoSourceModule *hao_find_module(HaoRuntime *host, const char *name) {
    for (HaoSourceModule *module = host->modules; module; module = module->next) {
        if (strcmp(module->name, name) == 0) return module;
    }
    return NULL;
}

static HaoNativeModule *hao_find_native_module(HaoRuntime *host, const char *name) {
    for (HaoNativeModule *module = host->native_modules; module; module = module->next) {
        if (strcmp(module->name, name) == 0) return module;
    }
    return NULL;
}

static char *hao_lexical_absolute(const char *path) {
    char *cwd = NULL;
    if (path[0] != '/') {
        cwd = getcwd(NULL, 0);
        if (!cwd) return NULL;
    }
    size_t path_len = strlen(path);
    size_t cwd_len = cwd ? strlen(cwd) : 0;
    if (path_len > SIZE_MAX - cwd_len - 2) { free(cwd); return NULL; }
    char *input = hao_alloc(cwd_len + path_len + 2);
    if (!input) { free(cwd); return NULL; }
    if (cwd) {
        memcpy(input, cwd, cwd_len);
        input[cwd_len] = '/';
        memcpy(input + cwd_len + 1, path, path_len + 1);
    } else {
        memcpy(input, path, path_len + 1);
    }
    free(cwd);
    char *output = hao_alloc(cwd_len + path_len + 2);
    if (!output) { hao_free(input); return NULL; }
    size_t written = 1;
    output[0] = '/';
    for (size_t index = 0; input[index];) {
        while (input[index] == '/') index++;
        size_t start = index;
        while (input[index] && input[index] != '/') index++;
        size_t length = index - start;
        if (!length || (length == 1 && input[start] == '.')) continue;
        if (length == 2 && input[start] == '.' && input[start + 1] == '.') {
            if (written > 1) {
                while (written > 1 && output[written - 1] != '/') written--;
                if (written > 1) written--;
            }
            continue;
        }
        if (written > 1) output[written++] = '/';
        memcpy(output + written, input + start, length);
        written += length;
    }
    output[written] = 0;
    hao_free(input);
    return output;
}

int hao_runtime_register(uintptr_t handle, const char *name, size_t name_len,
                         const char *source, size_t source_len) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!name_len || name_len == SIZE_MAX || source_len == SIZE_MAX ||
        memchr(name, 0, name_len)) return 1;
    HaoSourceModule *module = hao_calloc(1, sizeof(*module));
    if (!module) return 1;
    module->name = hao_alloc(name_len + 1);
    module->source = hao_alloc(source_len + 1);
    if (!module->name || !module->source) {
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        return 1;
    }
    memcpy(module->name, name, name_len);
    module->name[name_len] = 0;
    if (source_len) memcpy(module->source, source, source_len);
    module->source[source_len] = 0;
    module->source_len = source_len;
    if (hao_find_module(host, module->name) || hao_find_native_module(host, module->name)) {
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        return 1;
    }
    module->next = host->modules;
    host->modules = module;
    return 0;
}

int hao_runtime_register_native(uintptr_t handle, const char *name, size_t name_len,
                                void *(*load)(void *, const char *)) {
    HaoRuntime *host = (HaoRuntime *)handle;
    if (!name_len || name_len == SIZE_MAX || !load || memchr(name, 0, name_len)) return 1;
    HaoNativeModule *module = hao_calloc(1, sizeof(*module));
    if (!module) return 1;
    module->name = hao_strndup(name, name_len);
    if (!module->name || hao_find_module(host, module->name) ||
        hao_find_native_module(host, module->name)) {
        hao_free(module->name);
        hao_free(module);
        return 1;
    }
    module->load = load;
    module->next = host->native_modules;
    host->native_modules = module;
    return 0;
}

extern void hao_embed_clear_error(uintptr_t handle);
extern void hao_embed_invalid_buffer(uintptr_t handle);
extern void hao_embed_set_error(uintptr_t handle, const unsigned char *message, size_t length);

int hao_embed_register_native_module(HaoRuntimeHandle handle, const unsigned char *name,
                                     size_t name_len, HaoNativeModuleLoader loader) {
    if (!handle) return 1;
    if (!name && name_len) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    if (hao_runtime_register_native(handle, (const char *)name, name_len, loader) == 0) return 0;
    static const unsigned char failure[] = "Native module registration failed";
    hao_embed_set_error(handle, failure, sizeof(failure) - 1);
    return 1;
}

int hao_embed_register_package_callbacks(HaoRuntimeHandle handle, const unsigned char *name,
                                         size_t name_len, HaoPackageInstall install,
                                         HaoPackageDeinit deinit, void *userdata) {
    if (!handle) return 1;
    if (!name && name_len) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    HaoRuntime *host = (HaoRuntime *)handle;
    bool valid = name_len && name_len != SIZE_MAX && !memchr(name, 0, name_len);
    for (HaoPackageCallbacks *it = host->packages; valid && it; it = it->next) {
        if (strlen(it->name) == name_len && memcmp(it->name, name, name_len) == 0) valid = false;
    }
    HaoPackageCallbacks *entry = valid ? hao_calloc(1, sizeof(*entry)) : NULL;
    if (entry) entry->name = hao_strndup((const char *)name, name_len);
    if (!entry || !entry->name) {
        if (entry) { hao_free(entry->name); hao_free(entry); }
        static const unsigned char failure[] = "Package registration failed";
        hao_embed_set_error(handle, failure, sizeof(failure) - 1);
        return 1;
    }
    entry->install = install;
    entry->deinit = deinit;
    entry->userdata = userdata;
    entry->prev = host->last_package;
    if (host->last_package) host->last_package->next = entry;
    else host->packages = entry;
    host->last_package = entry;
    return 0;
}

static bool hao_package_owns(const unsigned char *package_name, size_t package_len,
                             const unsigned char *specifier, size_t specifier_len) {
    if (!specifier || !specifier_len || memchr(specifier, 0, specifier_len)) return false;
    bool standard = package_len == 3 && memcmp(package_name, "std", 3) == 0;
    if (standard) return specifier_len >= 4 && memcmp(specifier, "std:", 4) == 0;
    if (specifier_len >= 4 && memcmp(specifier, "std:", 4) == 0) return false;
    return specifier_len >= package_len && memcmp(specifier, package_name, package_len) == 0 &&
        (specifier_len == package_len || specifier[package_len] == ':');
}

static bool hao_same_name(const unsigned char *left, size_t left_len,
                          const unsigned char *right, size_t right_len) {
    return left_len == right_len && memcmp(left, right, left_len) == 0;
}

static void hao_rollback_package_modules(HaoRuntime *host, size_t source_count,
                                          size_t native_count) {
    while (source_count--) {
        HaoSourceModule *module = host->modules;
        host->modules = module->next;
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
    }
    while (native_count--) {
        HaoNativeModule *module = host->native_modules;
        host->native_modules = module->next;
        hao_free(module->name);
        hao_free(module);
    }
}

int hao_embed_register_package(HaoRuntimeHandle handle, const HaoEmbedPackage *package) {
    if (!handle || !package) return 1;
    if ((!package->name && package->name_len) ||
        (package->source_count && !package->sources) ||
        (package->native_count && !package->native_modules)) {
        hao_embed_invalid_buffer(handle);
        return 1;
    }
    hao_embed_clear_error(handle);
    HaoRuntime *host = (HaoRuntime *)handle;
    bool valid = package->name_len && package->name_len != SIZE_MAX &&
        !memchr(package->name, 0, package->name_len);
    for (HaoPackageCallbacks *it = host->packages; valid && it; it = it->next) {
        if (strlen(it->name) == package->name_len &&
            memcmp(it->name, package->name, package->name_len) == 0) valid = false;
    }
    for (size_t i = 0; valid && i < package->source_count; i++) {
        const HaoEmbedSourceModule *source = &package->sources[i];
        valid = source->specifier_len != SIZE_MAX && source->source_len != SIZE_MAX &&
            (source->source || !source->source_len) &&
            hao_package_owns(package->name, package->name_len,
                             source->specifier, source->specifier_len);
        if (!valid) break;
        for (size_t j = 0; j < i; j++) {
            const HaoEmbedSourceModule *prior = &package->sources[j];
            if (hao_same_name(source->specifier, source->specifier_len,
                              prior->specifier, prior->specifier_len)) valid = false;
        }
        for (size_t j = 0; j < package->native_count; j++) {
            const HaoEmbedNativeModule *native = &package->native_modules[j];
            if (native->specifier && hao_same_name(source->specifier, source->specifier_len,
                native->specifier, native->specifier_len)) valid = false;
        }
        char *name = valid ? hao_strndup((const char *)source->specifier, source->specifier_len) : NULL;
        if (!name || hao_find_module(host, name) || hao_find_native_module(host, name)) valid = false;
        hao_free(name);
    }
    for (size_t i = 0; valid && i < package->native_count; i++) {
        const HaoEmbedNativeModule *native = &package->native_modules[i];
        valid = native->specifier_len != SIZE_MAX && native->loader &&
            hao_package_owns(package->name, package->name_len,
                             native->specifier, native->specifier_len);
        if (!valid) break;
        for (size_t j = 0; j < i; j++) {
            const HaoEmbedNativeModule *prior = &package->native_modules[j];
            if (hao_same_name(native->specifier, native->specifier_len,
                              prior->specifier, prior->specifier_len)) valid = false;
        }
        char *name = valid ? hao_strndup((const char *)native->specifier, native->specifier_len) : NULL;
        if (!name || hao_find_module(host, name) || hao_find_native_module(host, name)) valid = false;
        hao_free(name);
    }
    size_t added_sources = 0, added_native = 0;
    for (size_t i = 0; valid && i < package->source_count; i++) {
        const HaoEmbedSourceModule *source = &package->sources[i];
        valid = hao_runtime_register(handle, (const char *)source->specifier, source->specifier_len,
                                     (const char *)source->source, source->source_len) == 0;
        if (valid) added_sources++;
    }
    for (size_t i = 0; valid && i < package->native_count; i++) {
        const HaoEmbedNativeModule *native = &package->native_modules[i];
        valid = hao_runtime_register_native(handle, (const char *)native->specifier,
                                            native->specifier_len, native->loader) == 0;
        if (valid) added_native++;
    }
    if (valid) valid = hao_embed_register_package_callbacks(handle, package->name,
        package->name_len, package->install, package->deinit, package->userdata) == 0;
    if (valid) return 0;
    hao_rollback_package_modules(host, added_sources, added_native);
    hao_embed_clear_error(handle);
    static const unsigned char failure[] = "Package registration failed";
    hao_embed_set_error(handle, failure, sizeof(failure) - 1);
    return 1;
}

int hao_package_install(HaoRuntime *host) {
    for (HaoPackageCallbacks *entry = host->packages; entry; entry = entry->next) {
        if (entry->install && entry->install((uintptr_t)host, entry->userdata) != 0) {
            static const unsigned char failure[] = "Package installation failed";
            hao_embed_set_error((uintptr_t)host, failure, sizeof(failure) - 1);
            return 1;
        }
    }
    return 0;
}

void hao_package_cleanup(HaoRuntime *host) {
    HaoPackageCallbacks *entry = host->last_package;
    while (entry) {
        HaoPackageCallbacks *previous = entry->prev;
        if (entry->deinit) entry->deinit((uintptr_t)host, entry->userdata);
        hao_free(entry->name);
        hao_free(entry);
        entry = previous;
    }
    host->packages = host->last_package = NULL;
}

char *hao_normalize_module(JSContext *ctx, const char *base,
                                   const char *specifier, void *opaque) {
    HaoRuntime *host = opaque;
    if (hao_find_module(host, specifier) || hao_find_native_module(host, specifier)) {
        size_t len = strlen(specifier);
        char *normalized = js_malloc(ctx, len + 1);
        if (normalized) memcpy(normalized, specifier, len + 1);
        return normalized;
    }
    if (strncmp(specifier, "./", 2) != 0 && strncmp(specifier, "../", 3) != 0) {
        unsigned char candidate[4096];
        int candidate_len = hao_resolve_package((const unsigned char *)base,
                                                (const unsigned char *)specifier,
                                                candidate, sizeof(candidate));
        if (candidate_len < 0) {
            const char *reason = candidate_len == -2 ? "CommonJS packages are not supported"
                : candidate_len == -3 ? "Package entry is not ESM-compatible"
                : candidate_len == -4 ? "Package manifest not found"
                : candidate_len == -5 ? "Package export not found"
                : "Cannot resolve module";
            JS_ThrowReferenceError(ctx, "%s: %s (from %s)", reason, specifier, base);
            return NULL;
        }
        candidate[candidate_len] = 0;
        char *resolved = hao_lexical_absolute((const char *)candidate);
        if (!resolved) {
            JS_ThrowReferenceError(ctx, "Package entry not found: %s", specifier);
            return NULL;
        }
        size_t len = strlen(resolved);
        const char *extension = strrchr(resolved, '.');
        bool addon = extension && (!strcmp(extension, ".dylib") || !strcmp(extension, ".so") ||
                                   !strcmp(extension, ".dll") || !strcmp(extension, ".node"));
        if (addon) len += strlen(specifier) + 7;
        char *normalized = js_malloc(ctx, len + 1);
        if (normalized) {
            if (addon) snprintf(normalized, len + 1, "addon:%s\n%s", specifier, resolved);
            else memcpy(normalized, resolved, len + 1);
        }
        hao_free(resolved);
        return normalized;
    }
    const char *slash = strrchr(base, '/');
    size_t dir_len = slash ? (size_t)(slash - base) : 1;
    size_t spec_len = strlen(specifier);
    char *joined = hao_alloc(dir_len + spec_len + 3);
    if (!joined) return NULL;
    if (slash) memcpy(joined, base, dir_len);
    else joined[0] = '.';
    joined[dir_len] = '/';
    memcpy(joined + dir_len + 1, specifier, spec_len + 1);
    char *resolved = hao_lexical_absolute(joined);
    hao_free(joined);
    if (!resolved) {
        JS_ThrowReferenceError(ctx, "Module not found: %s", specifier);
        return NULL;
    }
    size_t len = strlen(resolved);
    char *normalized = js_malloc(ctx, len + 1);
    if (normalized) memcpy(normalized, resolved, len + 1);
    hao_free(resolved);
    return normalized;
}

JSModuleDef *hao_load_module(JSContext *ctx, const char *name, void *opaque) {
    if (strncmp(name, "addon:", 6) == 0) return hao_load_addon(ctx, name);
    HaoRuntime *host = opaque;
    HaoNativeModule *native = hao_find_native_module(host, name);
    if (native) return native->load(ctx, name);
    HaoSourceModule *module = hao_find_module(host, name);
    if (module) {
        size_t name_len = strlen(name);
        char *typescript_path = hao_alloc(name_len + 4);
        if (!typescript_path) return NULL;
        memcpy(typescript_path, name, name_len);
        memcpy(typescript_path + name_len, ".ts", 4);
        char *transformed = hao_transpile_types_for_path(module->source, typescript_path);
        hao_free(typescript_path);
        if (!transformed) {
            char *error = hao_transpiler_last_error();
            JS_ThrowSyntaxError(ctx, "%s", error ? error : "Module transpilation failed");
            if (error) hao_transpiler_free(error);
            return NULL;
        }
        JSValue compiled = JS_Eval(ctx, transformed, strlen(transformed), name,
                                   JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        hao_transpiler_free(transformed);
        if (JS_IsException(compiled)) return NULL;
        JSModuleDef *result = JS_VALUE_GET_PTR(compiled);
        JS_FreeValue(ctx, compiled);
        return result;
    }
    FILE *file = fopen(name, "rb");
    if (!file) {
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    long size = ftell(file);
    if (size < 0 || size > 10 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    char *source = hao_alloc((size_t)size + 1);
    if (!source) {
        fclose(file);
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    size_t read_count = fread(source, 1, (size_t)size, file);
    fclose(file);
    if (read_count != (size_t)size) {
        hao_free(source);
        JS_ThrowReferenceError(ctx, "Module source not found");
        return NULL;
    }
    source[size] = 0;
    char *transformed = hao_transpile_types_for_path(source, name);
    hao_free(source);
    if (!transformed) {
        char *error = hao_transpiler_last_error();
        JS_ThrowSyntaxError(ctx, "%s", error ? error : "Module transpilation failed");
        if (error) hao_transpiler_free(error);
        return NULL;
    }
    JSValue compiled = JS_Eval(ctx, transformed, strlen(transformed), name,
                               JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    hao_transpiler_free(transformed);
    if (JS_IsException(compiled)) return NULL;
    JSModuleDef *compiled_module = JS_VALUE_GET_PTR(compiled);
    JS_FreeValue(ctx, compiled);
    return compiled_module;
}

void hao_module_cleanup(HaoRuntime *host) {
    HaoSourceModule *module = host->modules;
    while (module) {
        HaoSourceModule *next = module->next;
        hao_free(module->name);
        hao_free(module->source);
        hao_free(module);
        module = next;
    }
    HaoNativeModule *native = host->native_modules;
    while (native) {
        HaoNativeModule *next = native->next;
        hao_free(native->name);
        hao_free(native);
        native = next;
    }
}
