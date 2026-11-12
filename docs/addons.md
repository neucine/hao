# Native Addons

Native addons are dynamic libraries that export `js_register_modules`.
They use the C ABI in `include/addon.h` and can be imported from TypeScript with
package-owned specifiers such as `foo:native`.

`include/hao.h` defines the separate Cyna runtime embedding API.

## Package Layout

```text
node_modules/foo/
  package.json
  native.dylib   # macOS
  native.so      # Linux
  native.dll     # Windows
```

```json
{
  "type": "module",
  "exports": {
    "./native": "./native.dylib",
    "./extra": "./native.dylib"
  }
}
```

With that layout, a script can import:

```ts
import native from "foo:native"
import extra from "foo:extra"

native.foo()
extra.label()
```

The resolver treats `foo:native` as package `foo` with subpath `native`, then
loads the matching dynamic library. Multiple specifiers can point at the same
library when the addon registers multiple modules.

## C Entry Point

```c
#include "addon.h"

static JsValue foo(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;
    return js_string(ctx, "hao");
}

static const JsFunction functions[] = {
    { "foo", foo, 0 },
};

static const JsModule module = {
    .specifier = "foo:native",
    .functions = functions,
    .function_count = sizeof(functions) / sizeof(functions[0]),
};

int js_register_modules(JsRegistry* registry) {
    if (registry->api->abi_version != JS_ADDON_ABI_VERSION) {
        return -1;
    }
    return js_add_module(registry, &module);
}
```

## ABI Rules

- Export exactly one `js_register_modules` symbol.
- Check `registry->api->abi_version` before registering modules.
- Keep `JsModule`, `JsFunction`, names, and specifier strings alive for the
  lifetime of the loaded library.
- Set `JsModule.function_count` to the number of function entries.
- Treat `JsValue` handles as callback-local. Do not store them across calls.
- Copy strings returned by `js_to_string` if they need to outlive the callback.

## Values

The ABI can create primitives, objects, arrays, and errors:

```c
JsValue out = js_array(ctx);
js_array_set(ctx, out, 0, js_string(ctx, "left"));
js_array_set(ctx, out, 1, js_string(ctx, "right"));
return out;
```

Object properties use string keys:

```c
JsValue obj = js_object(ctx);
js_set_property(ctx, obj, "ok", js_bool(ctx, 1));
return obj;
```

Return `js_throw_type_error` or `js_throw_error` to raise JavaScript errors.

## Metrics

Native callbacks can emit telemetry without touching QuickJS directly. Register
the metric lazily, keep the returned id in static addon state, then update it
from later calls:

```c
static uint32_t calls_id;
static int calls_ready;

static JsValue work(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;

    if (!calls_ready) {
        JsMetricDefinition def = {
            .scope = "foo.native",
            .name = "calls",
            .kind = JS_METRIC_COUNTER,
            .unit = "count",
        };
        if (js_metric_register(ctx, &def, &calls_id) != 0) {
            return js_throw_error(ctx, "failed to register metric");
        }
        calls_ready = 1;
    }

    js_metric_add(ctx, calls_id, 1);
    return js_undefined(ctx);
}
```

TypeScript can inspect snapshots through `std:telemetry`:

```ts
import { metrics } from "std:telemetry"

console.log(metrics())
```

## Traces

ABI version 4 adds native trace context and span operations. A callback can
continue the JavaScript caller's trace, create a child span, add a structured
event, and end the span without constructing JavaScript objects:

```c
static JsValue work(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;

    JsTraceContext captured;
    if (js_trace_capture(ctx, &captured) < 0) {
        return js_throw_error(ctx, "trace capture failed");
    }
    JsSpanHandle scope = js_trace_enter(ctx, &captured);
    if (!scope) return js_throw_error(ctx, "trace enter failed");

    const JsTraceAttribute attributes[] = {
        {"queued", 1, 1, 0, 0.0, NULL},
    };
    const JsTraceSpanOptions options = {
        .root = 0,
        .kind = JS_SPAN_CLIENT,
        .source = "foo:native",
        .attributes = attributes,
        .attribute_count = 1,
    };
    JsSpanHandle span = 0;
    if (js_trace_span_start(ctx, "foo.work", &options, &span) < 0) {
        js_trace_exit(ctx, scope);
        return js_throw_error(ctx, "span start failed");
    }

    js_trace_span_event(ctx, span, "foo.invoke", NULL, 0);
    js_trace_span_end(ctx, span, JS_TRACE_STATUS_OK);
    js_trace_exit(ctx, scope);
    return js_undefined(ctx);
}
```

`js_trace_capture`, `js_trace_enter`, and `js_trace_exit` preserve context
around native work. `js_trace_span_start` creates a child of the active span
unless `root` is set. Attribute kinds are boolean, integer, float, and text,
with the same limits as JavaScript spans. ABI 4 appends these fields to
`JsContextApi`; existing metric fields retain their offsets.

Use filtered trace snapshots to inspect addon observations:

```ts
import { snapshotTraceRecordsNative } from "std:telemetry/native"

const addon = snapshotTraceRecordsNative(0, 100, {
  source_kind: "addon",
  source: "foo:native",
})
```

## Example

See `examples/native-addon/native.c` for a complete addon with string, number,
and array-returning functions.
