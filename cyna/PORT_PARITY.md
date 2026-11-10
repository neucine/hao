# Zig source parity audit

Reference: `legacy` at `e1f4b59`. Port: `cyna-port`. A matching path means an
implementation location, not proof of equivalent behavior. The end to end suite
currently exercises 20 files and 81 cases; it does not cover every Zig source
boundary.

Every legacy `src/**/*.zig` file except the following 16 has a same stem file
under `cyna/src/` with a `.cy`, `.c`, or `.ts` extension. These exceptions have
intentional implementation locations:

| Legacy source | Cyna port location | Reason for layout change |
| --- | --- | --- |
| `hao.zig` | `src/runtime.cy`, `src/std.cy`, `src/embed.cy` | Cyna modules and the embedding C ABI replace the Zig root export module. |
| `js/abi.zig`, `js/mod.zig` | `bridge.c`, `src/module.c`, `src/runtime_host.h` | QuickJS interop is at the C boundary; Cyna owns the runtime handle. |
| `link.zig` | `cyna.toml`, `build.sh` | Linking is declared in the Cyna build manifest. |
| `qjs.zig` | `src/runtime.cy`, `bridge.c`, `src/runtime_host.h` | Runtime ownership is in Cyna; QuickJS calls use its C API. |
| `std/ffi/Library.zig`, `std/ffi/runtime.zig`, `std/ffi/trampoline.zig`, `std/ffi/types.zig` | `src/std/ffi/native.c`, `src/std/ffi/native.ts` | One libffi adapter replaces the Zig library and call trampoline layers. |
| `std/test/registry.zig`, `std/test/runner.zig` | `src/std/test/native.ts`, `bridge.c` | The registry and runner operate on JavaScript callbacks in the same QuickJS context. |
| `telemetry/index.zig`, `telemetry/store.zig`, `telemetry/trace.zig` | `src/telemetry/interface.cy`, `src/telemetry/interface.c`, `src/std/telemetry/native.ts` | Cyna `std.telemetry` supplies the host backend; JavaScript keeps the public trace ring and cursor API. |
| `telemetry/server.zig` | `src/std/telemetry/console.ts`, `src/telemetry/dashboard.html` | The telemetry console uses the ported HTTP server and existing dashboard. |
| `transpiler.zig` | `bridge.c`, `src/module.c`, `../libs/transpiler/src/` | The Zig wrapper is replaced by direct calls to the existing Rust archive. |

The legacy TypeScript standard modules are byte identical in the port except
`std/http/index.ts`: the Cyna tree separates its HTTP server into
`std/http/server.ts`, while the legacy tree keeps client and server in one file.

## Open behavior checks

- Verify trace context while HTTP client work completes. The Zig native client
  captures and restores it; the Cyna port currently does not claim this parity.
- Compare the embedding surface and native addon ABI with the Zig host exports,
  including lifecycle and error propagation, using independent consumers.
- Compare Jupyter request, stream, display, history, and shutdown behavior with
  the Zig kernel beyond the current kernel integration test.
- Compare FFI declaration, marshaling, handle lifecycle, and error cases beyond
  the existing C ABI and direct binding cases.

This document is a source inventory and work list. Passing the current tests
does not close these checks.
