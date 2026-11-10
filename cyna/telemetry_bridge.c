#include <quickjs.h>
#include <malloc/malloc.h>
#include <stdint.h>

static JSValue memory_snapshot(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    JSMemoryUsage usage;
    JS_ComputeMemoryUsage(JS_GetRuntime(ctx), &usage);
    malloc_statistics_t zone;
    malloc_zone_statistics(malloc_default_zone(), &zone);
    JSValue result = JS_NewObject(ctx);
    if (JS_IsException(result)) return result;
#define GAUGE(name, value) JS_SetPropertyStr(ctx, result, name, JS_NewFloat64(ctx, (double)(value)))
    GAUGE("qjs_malloc_bytes", usage.malloc_size);
    GAUGE("qjs_malloc_limit_bytes", usage.malloc_limit);
    GAUGE("qjs_heap_used_bytes", usage.memory_used_size);
    GAUGE("qjs_malloc_count", usage.malloc_count);
    GAUGE("qjs_heap_used_count", usage.memory_used_count);
    GAUGE("qjs_atom_count", usage.atom_count);
    GAUGE("qjs_atom_bytes", usage.atom_size);
    GAUGE("qjs_string_count", usage.str_count);
    GAUGE("qjs_string_bytes", usage.str_size);
    GAUGE("qjs_object_count", usage.obj_count);
    GAUGE("qjs_object_bytes", usage.obj_size);
    GAUGE("qjs_property_count", usage.prop_count);
    GAUGE("qjs_property_bytes", usage.prop_size);
    GAUGE("qjs_shape_count", usage.shape_count);
    GAUGE("qjs_shape_bytes", usage.shape_size);
    GAUGE("qjs_function_count", usage.js_func_count);
    GAUGE("qjs_function_bytes", usage.js_func_size);
    GAUGE("qjs_function_code_bytes", usage.js_func_code_size);
    GAUGE("qjs_array_count", usage.array_count);
    GAUGE("qjs_fast_array_count", usage.fast_array_count);
    GAUGE("qjs_fast_array_element_count", usage.fast_array_elements);
    GAUGE("qjs_binary_object_count", usage.binary_object_count);
    GAUGE("qjs_binary_object_bytes", usage.binary_object_size);
    GAUGE("allocator_active_bytes", zone.size_in_use);
    GAUGE("allocator_peak_bytes", zone.max_size_in_use);
#undef GAUGE
    return result;
}
void hao_install_telemetry_globals(JSContext *ctx, JSValue global) {
    JS_SetPropertyStr(ctx, global, "__hao_telemetry_memorySnapshot", JS_NewCFunction(ctx, memory_snapshot, "memorySnapshot", 0));
}
