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
The Cyna HTTP client also captures a trace context before deferring its native
request. `std/telemetry/native.ts` contains the host context helpers needed by
that adapter.

## Open behavior checks

- The `std:fs` surface has matching public operations in the shared end to end
  suite: existence, read, write, and size. A direct Zig/Cyna comparison also
  matched file, symlink, missing path, and directory results. The smoke suite
  covers NUL truncation and the 100 MiB read limit. Concurrent file mutation
  during a read has not been compared.

- The `async/loop.zig` turn boundary has a direct port in `async/loop.cy` and
  `async/uv.c`: both check `uv_loop_alive` before `UV_RUN_ONCE` and report a
  serviced turn even when its final handle closes. `Loop.run_until_idle` also
  drains QuickJS jobs between turns. The smoke suite covers timer cancellation,
  callback errors, and a Promise job between two timer callbacks. This checks
  the timer path; other libuv handle types and shutdown ordering still need
  comparison.

- HTTP client trace context was a confirmed difference: with the same local
  HTTP server, `await trace('parent', async () => { await get(url);
  trace('child', () => {}); })` produced `{"sameTrace":true,"parented":true}`
  on Zig and `{"sameTrace":false,"parented":false}` on Cyna. The port now
  captures context before the deferred native request and drains its Promise
  jobs while the worker completion restores that context. The simple fixture
  and a smoke case with two concurrent requests and a rejected request now
  produce parented child spans. Further scheduling combinations remain part
  of the full parity audit.
- Compare the embedding surface and native addon ABI with the Zig host exports,
  including lifecycle and error propagation, using independent consumers.
  Zig exposes a Zig `RuntimeEnvironment` and `Package` API; the Cyna port currently
  exposes a C embedding ABI for source modules. Its consumer verifies two runtime
  lifetimes, error replacement, buffer validation, and source registration.
  Registration now rejects empty and NUL-containing specifiers explicitly,
  consistent with the Zig registry's empty package rejection and its
  length-aware specifiers. Native package registration and lifecycle callbacks
  remain an API parity gap.
  The native addon consumer now checks `js_array_length` for ordinary and
  sparse arrays. The Cyna adapter uses the same signed 32 bit conversion as
  Zig and rejects lengths above `INT32_MAX`.
  Addon value lookup now distinguishes invalid handles from the valid zero
  handle, which represents `undefined`. A shared C addon probe returns `15`
  under both the Zig and Cyna runtimes for invalid conversion and predicate
  checks.
- Compare Jupyter request, stream, display, history, and shutdown behavior with
  the Zig kernel beyond the current kernel integration test.
  The Cyna wire layer validates the HMAC and discards malformed multipart
  messages; its C wire test now checks recovery after a bad signature, an extra
  frame, and an oversized frame. The Cyna kernel also handles completion,
  inspection, history, silent execution, and user expressions beyond the Zig
  handler's request set. Those additions need their own behavior review and
  do not establish parity for the shared request types.
  The kernel integration test now sends an `execute_request` without `code`
  followed by a valid `kernel_info_request`. Cyna stays alive and answers the
  latter, matching Zig's early return before execution count changes.
- Compare FFI declaration, marshaling, handle lifecycle, and error cases beyond
  the existing C ABI and direct binding cases.
  A direct `std:ffi/native` fixture passed under both runtimes: opening libc,
  calling `getpid`, closing twice, and calling after close produced the same
  result types and `TypeError FFI: library has been closed`. The Cyna smoke
  fixture now checks a successful call before the duplicate close. The shared
  FFI end to end suite passes 4 Zig cases and 7 Cyna cases; three added Cyna
  cases cover invalid declarations and multiline type parsing. These checks
  do not cover all marshaling widths or C ABI policy combinations.
  A separate C library probe compared `u64` arguments and returns at 2^53,
  2^63, and `UINT64_MAX` under both runtimes. The observed JavaScript numbers,
  including rounding above 2^53, matched. The Cyna smoke fixture now retains
  the `UINT64_MAX` and 2^53 + 1 checks.
  Zig rejects a C function declaration with no final semicolon. Cyna's parser
  previously accepted `double sqrt(double x)`; it now rejects that form, and
  the smoke suite checks the rejected and accepted variants.

This document is a source inventory and work list. Passing the current tests
does not close these checks.
