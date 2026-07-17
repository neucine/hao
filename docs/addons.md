# Native Addons

Native addons are dynamic libraries that export `js_register_modules`.
They use the C ABI in `include/hao.h` and can be imported from TypeScript with
package-owned specifiers such as `foo:native`.

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
  "type": "module"
}
```

With that layout, a script can import:

```ts
import native from "foo:native"

native.foo()
```

The resolver treats `foo:native` as package `foo` with subpath `native`, then
loads the matching dynamic library.

## C Entry Point

```c
#include "hao.h"

static JsValue foo(JsContext* ctx, int argc, const JsValue* argv) {
    (void)argc;
    (void)argv;
    return js_string(ctx, "hao");
}

static const JsFunction functions[] = {
    { "foo", foo, 0 },
    { 0, 0, 0 },
};

static const JsModule module = {
    "foo:native",
    functions,
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
- End every function array with `{ 0, 0, 0 }`.
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

## Example

See `examples/native-addon/native.c` for a complete addon with string, number,
and array-returning functions.
