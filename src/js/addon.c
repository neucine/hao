#include "../../include/addon.h"
#include "../runtime_allocator.h"
#include <quickjs.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct AddonLibrary {
    JSContext *ctx;
    char *path;
    void *handle;
    const JsModule **modules;
    size_t count;
    struct AddonLibrary *next;
} AddonLibrary;

typedef struct AddonFrame {
    JSContext *ctx;
    int argc;
    const JSValueConst *argv;
    JSValue *owned;
    size_t count;
    char **strings;
    size_t string_count;
} AddonFrame;

static AddonLibrary *libraries;
extern int hao_metric_register(JSContext *, const JsMetricDefinition *, uint32_t *);
extern int hao_metric_add(JSContext *, uint32_t, double);
extern int hao_metric_set(JSContext *, uint32_t, double);
extern int hao_metric_observe(JSContext *, uint32_t, double);
extern int hao_metric_value(JSContext *, uint32_t, double *);

static bool frame_value(AddonFrame *frame, JsValue handle, JSValueConst *value) {
    if (handle == 0) { *value = JS_UNDEFINED; return true; }
    if (handle <= (size_t)frame->argc) { *value = frame->argv[handle - 1]; return true; }
    size_t index = handle - (size_t)frame->argc - 1;
    if (index >= frame->count) return false;
    *value = frame->owned[index];
    return true;
}

static JsValue frame_push(AddonFrame *frame, JSValue value) {
    JSValue *values = hao_realloc(frame->owned, (frame->count + 1) * sizeof(*values));
    if (!values) {
        JS_FreeValue(frame->ctx, value);
        JS_ThrowOutOfMemory(frame->ctx);
        return 0;
    }
    frame->owned = values;
    frame->owned[frame->count++] = value;
    return (size_t)frame->argc + frame->count;
}

static AddonFrame *frame_of(JsContext *ctx) { return ctx->data; }
static JsValue api_undefined(JsContext *ctx) { return frame_push(frame_of(ctx), JS_UNDEFINED); }
static JsValue api_null(JsContext *ctx) { return frame_push(frame_of(ctx), JS_NULL); }
static JsValue api_bool(JsContext *ctx, int v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewBool(f->ctx, v)); }
static JsValue api_int(JsContext *ctx, int32_t v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewInt32(f->ctx, v)); }
static JsValue api_float(JsContext *ctx, double v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewFloat64(f->ctx, v)); }
static JsValue api_string(JsContext *ctx, const char *v) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewString(f->ctx, v)); }
static int api_to_bool(JsContext *ctx, JsValue v, int *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; int result = JS_ToBool(f->ctx, value); if (result < 0) return -1; *out = result; return 0; }
static int api_to_int(JsContext *ctx, JsValue v, int32_t *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; return JS_ToInt32(f->ctx, out, value); }
static int api_to_float(JsContext *ctx, JsValue v, double *out) { AddonFrame *f = frame_of(ctx); JSValueConst value; if (!frame_value(f, v, &value)) return -1; return JS_ToFloat64(f->ctx, out, value); }
static const char *api_to_string(JsContext *ctx, JsValue v) {
    AddonFrame *f = frame_of(ctx);
    JSValueConst value;
    if (!frame_value(f, v, &value)) return NULL;
    const char *text = JS_ToCString(f->ctx, value);
    if (!text) return NULL;
    char *copy = hao_strdup(text);
    JS_FreeCString(f->ctx, text);
    if (!copy) return NULL;
    char **strings = hao_realloc(f->strings, (f->string_count + 1) * sizeof(*strings));
    if (!strings) { hao_free(copy); return NULL; }
    f->strings = strings;
    f->strings[f->string_count++] = copy;
    return copy;
}
static JsValue api_type_error(JsContext *ctx, const char *message) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_ThrowTypeError(f->ctx, "%s", message)); }
static JsValue api_error(JsContext *ctx, const char *message) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_ThrowInternalError(f->ctx, "%s", message)); }
static JsValue api_object(JsContext *ctx) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewObject(f->ctx)); }
static int api_set(JsContext *ctx, JsValue object, const char *key, JsValue value) { AddonFrame *f = frame_of(ctx); JSValueConst target, item; if (!frame_value(f, object, &target) || !frame_value(f, value, &item)) return -1; return JS_DefinePropertyValueStr(f->ctx, target, key, JS_DupValue(f->ctx, item), JS_PROP_HAS_VALUE | JS_PROP_HAS_ENUMERABLE | JS_PROP_ENUMERABLE); }
static JsValue api_get(JsContext *ctx, JsValue object, const char *key) { AddonFrame *f = frame_of(ctx); JSValueConst target; if (!frame_value(f, object, &target)) return frame_push(f, JS_ThrowInternalError(f->ctx, "invalid object handle")); return frame_push(f, JS_GetPropertyStr(f->ctx, target, key)); }
static int api_is_undefined(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsUndefined(value); }
static int api_is_null(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsNull(value); }
static int api_is_object(JsContext *ctx, JsValue v) { JSValueConst value; return frame_value(frame_of(ctx), v, &value) && JS_IsObject(value); }
static int api_is_array(JsContext *ctx, JsValue v) { AddonFrame *f = frame_of(ctx); JSValueConst value; return frame_value(f, v, &value) && JS_IsArray(value); }
static int api_is_function(JsContext *ctx, JsValue v) { AddonFrame *f = frame_of(ctx); JSValueConst value; return frame_value(f, v, &value) && JS_IsFunction(f->ctx, value); }
static int api_array_length(JsContext *ctx, JsValue v, uint32_t *out) {
    AddonFrame *f = frame_of(ctx);
    JSValueConst array;
    if (!frame_value(f, v, &array)) return -1;
    JSValue len = JS_GetPropertyStr(f->ctx, array, "length");
    int32_t signed_length = 0;
    int status = JS_ToInt32(f->ctx, &signed_length, len);
    JS_FreeValue(f->ctx, len);
    if (status < 0 || signed_length < 0) return -1;
    *out = (uint32_t)signed_length;
    return 0;
}
static JsValue api_array_get(JsContext *ctx, JsValue v, uint32_t i) { AddonFrame *f = frame_of(ctx); JSValueConst array; if (!frame_value(f, v, &array)) return frame_push(f, JS_ThrowInternalError(f->ctx, "invalid array handle")); return frame_push(f, JS_GetPropertyUint32(f->ctx, array, i)); }
static JsValue api_array(JsContext *ctx) { AddonFrame *f = frame_of(ctx); return frame_push(f, JS_NewArray(f->ctx)); }
static int api_array_set(JsContext *ctx, JsValue v, uint32_t i, JsValue item) { AddonFrame *f = frame_of(ctx); JSValueConst array, value; if (!frame_value(f, v, &array) || !frame_value(f, item, &value)) return -1; return JS_DefinePropertyValueUint32(f->ctx, array, i, JS_DupValue(f->ctx, value), JS_PROP_HAS_VALUE | JS_PROP_HAS_ENUMERABLE | JS_PROP_ENUMERABLE); }
static int api_metric_register(JsContext *ctx, const JsMetricDefinition *d, uint32_t *id) { return hao_metric_register(frame_of(ctx)->ctx, d, id); }
static int api_metric_add(JsContext *ctx, uint32_t id, double value) { return hao_metric_add(frame_of(ctx)->ctx, id, value); }
static int api_metric_set(JsContext *ctx, uint32_t id, double value) { return hao_metric_set(frame_of(ctx)->ctx, id, value); }
static int api_metric_observe(JsContext *ctx, uint32_t id, double value) { return hao_metric_observe(frame_of(ctx)->ctx, id, value); }
static int api_metric_value(JsContext *ctx, uint32_t id, double *value) { return hao_metric_value(frame_of(ctx)->ctx, id, value); }

static const JsContextApi context_api = {
    .abi_version = JS_ADDON_ABI_VERSION, .undefined = api_undefined, .null_value = api_null,
    .bool_value = api_bool, .int32_value = api_int, .float64_value = api_float,
    .string_value = api_string, .to_bool = api_to_bool, .to_int32 = api_to_int,
    .to_float64 = api_to_float, .to_string = api_to_string,
    .throw_type_error = api_type_error, .throw_error = api_error,
    .object_value = api_object, .set_property = api_set, .get_property = api_get,
    .is_undefined = api_is_undefined, .is_null = api_is_null, .is_object = api_is_object,
    .is_array = api_is_array, .is_function = api_is_function, .array_length = api_array_length,
    .array_get = api_array_get, .array_value = api_array, .array_set = api_array_set,
    .metric_register = api_metric_register, .metric_add = api_metric_add,
    .metric_set = api_metric_set, .metric_observe = api_metric_observe,
    .metric_value = api_metric_value,
};

static JSValue call_addon(JSContext *ctx, JSValueConst this_value, int argc,
                          JSValueConst *argv, int magic, JSValue *data) {
    (void)this_value; (void)magic;
    int64_t pointer = 0;
    if (JS_ToInt64(ctx, &pointer, data[0]) < 0) return JS_EXCEPTION;
    const JsFunction *function = (const JsFunction *)(uintptr_t)pointer;
    AddonFrame frame = {.ctx = ctx, .argc = argc, .argv = argv};
    JsContext addon_ctx = {.api = &context_api, .data = &frame};
    JsValue *handles = hao_calloc((size_t)argc ? (size_t)argc : 1, sizeof(*handles));
    if (!handles) return JS_ThrowOutOfMemory(ctx);
    for (int i = 0; i < argc; i++) handles[i] = (size_t)i + 1;
    JsValue returned = function->callback(&addon_ctx, argc, handles);
    hao_free(handles);
    JSValueConst returned_value;
    JSValue result = frame_value(&frame, returned, &returned_value) ?
        JS_DupValue(ctx, returned_value) : JS_EXCEPTION;
    for (size_t i = 0; i < frame.count; i++) JS_FreeValue(ctx, frame.owned[i]);
    for (size_t i = 0; i < frame.string_count; i++) hao_free(frame.strings[i]);
    hao_free(frame.owned); hao_free(frame.strings);
    return result;
}

static int init_module(JSContext *ctx, JSModuleDef *module) {
    JSValue private = JS_GetModulePrivateValue(ctx, module);
    int64_t pointer = 0;
    if (JS_ToInt64(ctx, &pointer, private) < 0) return -1;
    const JsModule *entry = (const JsModule *)(uintptr_t)pointer;
    JSValue exports = JS_NewObject(ctx);
    if (JS_IsException(exports)) return -1;
    for (size_t i = 0; i < entry->function_count; i++) {
        const JsFunction *function = &entry->functions[i];
        JSValue data = JS_NewInt64(ctx, (int64_t)(uintptr_t)function);
        JSValue value = JS_NewCFunctionData(ctx, call_addon, function->length, 0, 1, &data);
        JS_FreeValue(ctx, data);
        if (JS_IsException(value)) { JS_FreeValue(ctx, exports); return -1; }
        if (JS_SetModuleExport(ctx, module, function->name, JS_DupValue(ctx, value)) < 0 ||
            JS_SetPropertyStr(ctx, exports, function->name, value) < 0) {
            JS_FreeValue(ctx, exports); return -1;
        }
    }
    return JS_SetModuleExport(ctx, module, "default", exports);
}

static int add_module(JsRegistry *registry, const JsModule *module) {
    AddonLibrary *library = registry->data;
    if (!module || !module->specifier || !module->functions || module->function_count == 0 || module->function_count > 256) return -1;
    const JsModule **modules = hao_realloc(library->modules, (library->count + 1) * sizeof(*modules));
    if (!modules) return -1;
    library->modules = modules;
    library->modules[library->count++] = module;
    return 0;
}
static const JsRegistryApi registry_api = {.abi_version = JS_ADDON_ABI_VERSION, .add_module = add_module};

static AddonLibrary *load_library(JSContext *ctx, const char *path) {
    for (AddonLibrary *it = libraries; it; it = it->next)
        if (it->ctx == ctx && strcmp(it->path, path) == 0) return it;
    AddonLibrary *library = hao_calloc(1, sizeof(*library));
    if (!library) return NULL;
    library->ctx = ctx;
    library->path = hao_strdup(path);
    library->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    JsRegisterModulesFn register_fn = library->handle ? (JsRegisterModulesFn)dlsym(library->handle, "js_register_modules") : NULL;
    JsRegistry registry = {.api = &registry_api, .data = library};
    if (!library->path || !register_fn || register_fn(&registry) != 0) {
        JS_ThrowReferenceError(ctx, "Cannot load native addon: %s", path);
        if (library->handle) dlclose(library->handle);
        hao_free(library->modules); hao_free(library->path); hao_free(library);
        return NULL;
    }
    library->next = libraries;
    libraries = library;
    return library;
}

JSModuleDef *hao_load_addon(JSContext *ctx, const char *name) {
    const char *newline = strchr(name, '\n');
    if (strncmp(name, "addon:", 6) != 0 || !newline) return NULL;
    char *specifier = hao_strndup(name + 6, (size_t)(newline - name - 6));
    if (!specifier) return NULL;
    AddonLibrary *library = load_library(ctx, newline + 1);
    if (!library) { hao_free(specifier); return NULL; }
    const JsModule *entry = NULL;
    for (size_t i = 0; i < library->count; i++)
        if (strcmp(library->modules[i]->specifier, specifier) == 0) { entry = library->modules[i]; break; }
    if (!entry && library->count == 1) entry = library->modules[0];
    hao_free(specifier);
    if (!entry) { JS_ThrowReferenceError(ctx, "Native addon module not registered: %s", name); return NULL; }
    JSModuleDef *module = JS_NewCModule(ctx, name, init_module);
    if (!module) return NULL;
    JS_SetModulePrivateValue(ctx, module, JS_NewInt64(ctx, (int64_t)(uintptr_t)entry));
    JS_AddModuleExport(ctx, module, "default");
    for (size_t i = 0; i < entry->function_count; i++) JS_AddModuleExport(ctx, module, entry->functions[i].name);
    return module;
}

void hao_addon_cleanup(JSContext *ctx) {
    AddonLibrary **link = &libraries;
    while (*link) {
        AddonLibrary *library = *link;
        if (library->ctx != ctx) { link = &library->next; continue; }
        *link = library->next;
        dlclose(library->handle);
        hao_free(library->modules); hao_free(library->path); hao_free(library);
    }
}
