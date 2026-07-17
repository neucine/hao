# Embedding Hao

Hao exposes one environment from Zig. It owns the runtime, async loop, globals,
module loader, package registry support, and optionally the built-in `std:`
modules.

Use `RuntimeEnvironment` with `.std = false` when an application wants to own its
module surface. Use `.std = true` for the same batteries-included behavior as the
`hao` CLI.

## Runtime Environment

```zig
const std = @import("std");
const hao = @import("hao");

pub fn runScript(source: []const u8) !void {
    var host = try hao.RuntimeEnvironment.init(std.heap.page_allocator, .{ .std = false });
    defer host.deinit();

    var registry = hao.Registry.init(std.heap.page_allocator);
    defer registry.deinit();

    const sources = [_]hao.SourceModule{.{
        .specifier = "app:main",
        .source = source,
    }};
    try registry.register(.{
        .name = "app",
        .sources = &sources,
    });
    var package_context = hao.package.PackageContext{
        .runtime = &host.runtime,
        .allocator = std.heap.page_allocator,
    };
    defer registry.deinitPackages(&package_context);

    try host.evalModuleSourceWithRegistry(
        "import 'app:main';",
        "<app>",
        &registry,
    );
    try host.runUntilIdle();
}
```

`RuntimeEnvironment.installGlobals()` installs `RuntimeError`, `console`, and timers.
It does not register the built-in `std:` standard modules, and it does not initialize
the `std:test` registry.

When using `RuntimeEnvironment`, the caller owns package lifecycle. If a package installs
native state or stores JavaScript values, call `registry.deinitPackages()` before
deinitializing the host runtime.

## Standard Modules

```zig
var host = try hao.RuntimeEnvironment.initWithIo(allocator, io, .{ .std = true });
defer host.deinit();

try host.runFile("main.ts");
```

With `.std = true`, the environment registers the built-in `std:` modules and
wires IO-backed native modules such as `std:process` and `std:http`.

## Version

Hosts can read the Hao package version from Zig:

```zig
std.debug.print("Hao {s}\n", .{hao.version});
```

## Packages

A package owns a specifier prefix. The `std:` prefix is reserved for Hao
standard modules. Internally, those modules use the same package lifecycle as
host packages.

```zig
const sources = [_]hao.SourceModule{.{
    .specifier = "demo:hello",
    .source = "export const value = 42;",
}};

try registry.register(.{
    .name = "demo",
    .sources = &sources,
});
```

Host packages should use product prefixes such as `demo:` or `app:`. Native
packages can also provide loader-backed native modules through
`hao.NativeModule`.

## Event Loop

`runUntilIdle()` drains QuickJS promise jobs and the libuv loop until both are
idle. Call it after evaluating scripts that schedule timers, async native work,
or promises that resolve through host callbacks.
