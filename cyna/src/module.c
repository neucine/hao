#include "runtime_host.h"
#include "runtime_allocator.h"
#include "../../include/hao.h"
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
    memcpy(module->source, source, source_len);
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
            JS_ThrowReferenceError(ctx, "Cannot resolve package: %s", specifier);
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
        JS_ThrowReferenceError(ctx, "Module not found: %s", name);
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size < 0 || size > 10 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    char *source = hao_alloc((size_t)size + 1);
    if (!source) {
        fclose(file);
        return NULL;
    }
    size_t read_count = fread(source, 1, (size_t)size, file);
    fclose(file);
    if (read_count != (size_t)size) {
        hao_free(source);
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
