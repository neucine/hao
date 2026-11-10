# Embedding Hao

## Cyna Runtime C API

The Cyna port builds `cyna/embed/build/libhao-cyna-embed.a` and exposes its C
interface in `include/hao.h`. Create a runtime with `hao_embed_new`, register
source modules with `hao_embed_register_module`, evaluate a module with
`hao_embed_eval`, drain pending Promise and native work with
`hao_embed_run_until_idle`, and release the handle with `hao_embed_free`.
`hao_embed_install_std` installs the standard modules from the directory
produced by `sh cyna/build.sh` (`cyna/build/modules`). An application that does
not use `std:` modules can omit that call.
Hosts compiled separately can compare `hao_embed_abi_version()` with
`HAO_EMBED_ABI_VERSION` before creating a runtime.
Each successful `hao_embed_new` call owns an independent module registry and
must be paired with one `hao_embed_free` call. Source and module names are copied
before registration returns. A null byte pointer is accepted only with a zero
length. Calls return zero on success. After a failed operation,
call, `hao_embed_last_error` returns the full error length and copies a
null-terminated message into a caller-owned buffer. A successful subsequent
operation clears that message. Runtime errors are also written to stderr.

The archive currently targets macOS arm64. Link it with the Cyna runtime and
standard library archives, QuickJS, libuv, the Hao transpiler, libcurl, and
libffi, and libzmq. The exact compiler and linker invocation used by the checked C
consumer is in `cyna/test/smoke.sh`.

## Zig Runtime Environment

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
    var environment = try hao.RuntimeEnvironment.init(std.heap.page_allocator, .{ .std = false });
    defer environment.deinit();

    const sources = [_]hao.SourceModule{.{
        .specifier = "app:main",
        .source = source,
    }};
    try environment.registerPackage(.{
        .name = "app",
        .sources = &sources,
    });

    try environment.evalModuleSource(
        "import 'app:main';",
        "<app>",
    );
    try environment.runUntilIdle();
}
```

`RuntimeEnvironment.installGlobals()` installs `RuntimeError`, `console`, and timers.
The environment owns package registration and package lifecycle.

## Standard Modules

```zig
var environment = try hao.RuntimeEnvironment.initWithIo(allocator, io, .{ .std = true });
defer environment.deinit();

try environment.runFile("main.ts");
```

With `.std = true`, the environment registers the built-in `std:` modules and
wires IO-backed native modules such as `std:process` and `std:http`.

## Version

The Hao package version is available from Zig:

```zig
std.debug.print("Hao {s}\n", .{hao.version});
```

## Packages

A package owns a specifier prefix. The `std:` prefix is reserved for Hao
standard modules. Internally, those modules use the same package lifecycle as
application packages.

With an existing `RuntimeEnvironment`, register the package directly:

```zig
const sources = [_]hao.SourceModule{.{
    .specifier = "demo:hello",
    .source = "export const value = 42;",
}};

try environment.registerPackage(.{
    .name = "demo",
    .sources = &sources,
});
```

Application packages should use product prefixes such as `demo:` or `app:`. Native
packages can also provide loader-backed native modules through
`hao.NativeModule`.

## Event Loop

`runUntilIdle()` drains QuickJS promise jobs and the libuv loop until both are
idle. Call it after evaluating scripts that schedule timers, async native work,
or promises that resolve through runtime callbacks.
