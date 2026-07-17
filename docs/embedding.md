# Embedding Hao

Hao exposes two host layers from Zig:

- `hao.CoreHost`: runtime, async loop, globals, module loader, and package registry support.
- `hao.Host`: `CoreHost` plus the built-in `hao:` standard package and test/runtime conveniences used by the CLI.

Use `CoreHost` when an application wants to own its module surface. Use `Host`
when the application wants the same batteries-included behavior as the `hao`
CLI.

## Core Host

```zig
const std = @import("std");
const hao = @import("hao");

pub fn runScript(source: []const u8) !void {
    var host = try hao.CoreHost.init(std.heap.page_allocator);
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

    try host.evalModuleSourceWithRegistry(
        "import 'app:main';",
        "<app>",
        &registry,
    );
    try host.runUntilIdle();
}
```

`CoreHost.installGlobals()` installs `RuntimeError`, `console`, and timers.
It does not register the built-in `hao:` package, and it does not initialize
the `hao:test` registry.

## Standard Host

```zig
var host = try hao.Host.initWithIo(allocator, io);
defer host.deinit();

try host.runFile("main.ts");
```

`Host` registers the built-in `hao:` modules and wires IO-backed native modules
such as `hao:process` and `hao:http`.

## Packages

A package owns a specifier prefix. The `hao:` prefix is reserved for Hao.

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
