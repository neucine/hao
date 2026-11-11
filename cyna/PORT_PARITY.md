# Zig source parity audit

Reference: `legacy` at `e1f4b59`. Port: `cyna-port`. A matching path means an
implementation location, not proof of equivalent behavior. The end to end suite
currently exercises 20 files and 82 cases; it does not cover every Zig source
boundary.
On the current trees, `hao test test/e2e` passed 67 Zig cases with 7 skips and
75 Cyna cases with 7 skips. The Cyna branch adds eight cases, so these totals
are suite health evidence rather than proof of behavior parity. Running the
unchanged `legacy` suite under the Cyna binary with
`python3 cyna/test/legacy_e2e.py` also passes 67 cases with 7 skips. This
directly checks legacy suite behavior under Cyna while leaving untested source
boundaries in the open list below.
The `cyna-port` CI runs TypeScript, C header, and script checks. Native build
and smoke verification currently run locally with pinned Cyna 0.5.1-beta.1;
that compiler distribution is not published at the public download endpoint.
The public 0.5.0 release also lacks `std.config`, which this port uses.

Every legacy `src/**/*.zig` file except the following 16 has a same stem file
under `cyna/src/` with a `.cy`, `.c`, or `.ts` extension. These exceptions have
intentional implementation locations:
`python3 cyna/test/source_inventory.py` checks this inventory against the
`legacy` Git tree, including the existence of every mapped port location;
the `cyna-port` CI runs it after fetching `legacy`. This checks file coverage,
while behavior parity still requires the comparisons below.

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

The Cyna configuration path uses `std.config` for Boolean and positive integer
parsing. A direct Zig/Cyna acceptance comparison covered stack size, GC
threshold, libuv pool size, trace capacity, native stack traces, and telemetry
console ports across valid and invalid values. It found that Zig accepts signed
zero for the console port; Cyna now accepts it too, and the smoke suite retains
`-00` as a regression case. The compared values now have the same accept or
reject result.
  A live console comparison found that `/api/metrics` includes all ten Zig
  host memory metric names. Cyna also exposes QuickJS metrics supplied by
  `std.telemetry`; the smoke suite now guards the shared host metric set.
  `/api/traces` returned matching cursor and record shapes in the sampled
  requests. Cyna returns 404 for `/tracesXYZ`, whereas Zig's prefix route
  accepts it; Cyna keeps exact path matching.

The console bridge matched Zig for empty calls, primitives, nested objects,
cycles, and Error values in a direct stdout/stderr comparison. For a JavaScript
`Symbol`, Zig's inspect conversion writes an empty string, while Cyna writes
`Symbol(x)`. Cyna keeps the informative representation as an intentional
improvement, with a smoke check.

## Open behavior checks

- `RUNTIME_NATIVE_STACK_TRACE` now passes through Cyna `std.config` and makes
  classified C FFI declaration errors carry a captured C stack in
  `nativeStack`. With the flag enabled, Zig and Cyna both produce a string
  beginning with `SyntaxError`; with it disabled, Cyna leaves the field
  undefined. Unsupported declarations and platform width integer types now
  use Zig's `UnsupportedFeature` prefix. Other native error paths and exact
  stack frames remain to be
  compared. A direct `std:util` fixture covering primitives, arrays, objects,
  cycles, `repr()`, and inspect options produced identical output on both
  runtimes.

- The `std:fs` surface has matching public operations in the shared end to end
  suite: existence, read, write, and size. A direct Zig/Cyna comparison also
  matched file, symlink, missing path, and directory results. The smoke suite
  covers NUL truncation and the 100 MiB read limit. The Cyna file reader now
  sizes and reads through one open handle, as Zig does, so a separate `stat`
  call cannot race a subsequent open. It reads the initially sized content
  when a file grows during the read, matching Zig's read path. Concurrent
  mutation during a read has not been exercised directly.

- The `std:process` native boundary matched Zig in a direct matrix covering
  malformed options, argument arrays, working directories, output limits,
  exit codes, and environment lookup. The smoke suite now retains the
  representative option errors alongside its existing subprocess and NUL
  cases. The Cyna console preserves the embedded NUL in a printed input
  label where Zig truncates it; both lookups return the same environment value.

- The `async/loop.zig` turn boundary has a direct port in `async/loop.cy` and
  `async/uv.c`: both check `uv_loop_alive` before `UV_RUN_ONCE` and report a
  serviced turn even when its final handle closes. `Loop.run_until_idle` also
  drains QuickJS jobs between turns. The smoke suite covers timer cancellation,
  callback errors, and a Promise job between two timer callbacks. This checks
  the timer path. A shared nested timer probe additionally matched cancellation,
  Promise job draining, and scheduling a new timer inside a callback. Other
  libuv handle types and shutdown ordering still need comparison.
  Notebook Promise waiting now follows Zig's 64 idle turn cutoff and reports
  a libuv run failure. The kernel consumer checks that an unresolved Promise
  yields `Promise did not settle`, then accepts a later request. Its shared
  mode passes with both the Zig and Cyna binaries.
  A shared kernel probe also confirmed that a timer callback failure must
  interrupt a pending Promise. Cyna now forwards pending callback failures and
  unhandled rejections during notebook waiting. The Promise handlers retain
  their state after an early error, so a later cell does not receive a stray
  callback failure when the old Promise eventually settles.

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
  Zig exposes a Zig `RuntimeEnvironment` and `Package` API; the Cyna port exposes
  a C embedding ABI for source and native modules. Its consumer verifies two runtime
  lifetimes, error replacement, buffer validation, and source registration.
  Registration now rejects empty and NUL-containing specifiers explicitly,
  consistent with the Zig registry's empty package rejection and its
  length-aware specifiers. A host callback can now create a native QuickJS
  module under a registered specifier; the consumer imports one and checks
  duplicate rejection. Package install and deinit callbacks now run in Zig's
  registration and reverse registration orders. The C consumer checks two
  evaluations, duplicate package names, failure propagation, and one deinit
  pass even when installation fails. The embedding ABI is version 5. An
  atomic package registration call now validates ownership and duplicates,
  copies source modules, and registers native loaders and callbacks together.
  The C consumer checks a mixed source/native package and verifies rejection
  leaves no partially registered module.
  The native addon consumer now checks `js_array_length` for ordinary and
  sparse arrays. The Cyna adapter uses the same signed 32 bit conversion as
  Zig and rejects lengths above `INT32_MAX`.
  Addon value lookup now distinguishes invalid handles from the valid zero
  handle, which represents `undefined`. A shared C addon probe returns `15`
  under both the Zig and Cyna runtimes for invalid conversion and predicate
  checks.
  The shared compiled addon now also checks conversion failures for missing,
  `Symbol`, and throwing numeric arguments, plus array length results for
  null, scalar, `Symbol`, empty, and populated inputs. Zig and Cyna produced
  identical output for these cases.
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
  A shared mode of the C kernel consumer now runs unchanged against both
  binaries and passes kernel info, a simple execute result with idle status,
  an empty string result with no output packet, stdout stream, rich SVG display,
  an execution error with its IOPub error
  packet, and control shutdown. The wider Cyna test still exercises Cyna
  additions. It also checks an embedded NUL in a cell result: the Cyna bridge
  retains the full string and JSON encodes the control byte. Zig's current
  `jsonEscape` emits a raw NUL in this packet, so this is a deliberate
  valid JSON improvement. Broader message and scheduling combinations remain
  open.
  The shared kernel consumer now also checks `is_complete_request` and
  `comm_info_request` under both runtimes. Both reply with the expected
  completion status and comm map after earlier execute errors, and then
  continue to accept control shutdown.
  The shared consumer now checks execution counts of 1, 2, and 5 across a
  successful cell, an empty result, and a later failing cell. Both runtimes
  preserve the count sequence; the assertion accepts JSON whitespace differences.
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
  A shared C width probe matched `i8` and `u8` argument truncation and returns.
  For `f32`, Cyna returns the correctly rounded float value
  `1.100000023841858` from `hao_echo_f32(1.1)`, while Zig's current trampoline
  returns `1.273197475e-314`. The Cyna smoke suite now retains this ABI check;
  the correct `f32` result is an intentional improvement over Zig's bug.
  Zig rejects a C function declaration with no final semicolon. Cyna's parser
  previously accepted `double sqrt(double x)`; it now rejects that form, and
  the smoke suite checks the rejected and accepted variants. Function pointer
  parameters now use Zig's `UnsupportedFeature` classification instead of a
  generic invalid declaration error; the native stack smoke fixture checks it.
  A missing declared C symbol now produces the same `RuntimeError` code
  `io_error`, `SymbolNotFound` message suffix, and native stack label under
  both runtimes. Previously Cyna passed through the adapter's `InternalError`.
  C ABI status policy failures now construct `RuntimeError` as Zig does, with
  the configured code and an `internal` fallback for unrecognized codes. A
  shared native function probe matched the name, code, and message for both
  `io_error` and an unknown policy code.
  The exported `std:ffi/c/native` `prepareNative` function now returns Zig's
  `{ descriptor, policies }` shape instead of exposing Cyna's internal parser
  record. Direct Zig/Cyna comparisons matched scalar descriptors and an
  inferred opaque handle output policy. The smoke suite also checks that
  policy forms Zig cannot represent in a descriptor report the same
  `RuntimeError` category. More declaration and option combinations remain
  to be compared.
  A declaration matrix found a duplicate function error mismatch. Both
  `prepareNative` and `openNative` now report Zig's
  `declaration lowering failed: DuplicateFunctionName` message for this case.
  The declaration matrix now also matches Zig for unsupported primitive types,
  function pointer declarations, and missing semicolons. The smoke suite
  covers these `prepareNative` cases; other declaration forms and option
  combinations still need comparison.
  A second declaration matrix now matches Zig for empty declarations, an
  opaque typedef without functions, duplicate parameter and type names,
  unknown named types, and several malformed declarations. Zig accepts a
  self-referential POD declaration during descriptor preparation. Cyna now
  accepts that declaration too, while rejecting a call that would require its
  impossible by-value layout before entering native code. The smoke suite
  covers both outcomes. A direct Zig/Cyna probe now also matches descriptor
  preparation and the runtime `unsupported POD struct layout` error for
  pointer fields inside POD structs. Native marshaling of such fields remains
  unsupported in both runtimes.
  Policy probes now match Zig's public errors for unknown function options,
  invalid output parameters, unknown buffer parameters, non-size buffer
  lengths, and invalid search strategies. Zig converts numeric search paths to
  strings for opening a library; Cyna now does the same without modifying the
  caller's options, including frozen objects. The Zig reference exits with a
  segmentation fault for unknown handle policies and invalid close symbols
  in isolated probes, while Cyna returns an error. Those cases cannot use an identical
  error comparison until the Zig reference behavior is repaired.
  An expanded syntax matrix matched Zig for whitespace, pointer spelling,
  comments, unsupported arrays and unions, bitfields, standalone struct
  references, mismatched opaque typedef aliases, and empty POD declarations.
  The last four cases needed parser changes and have smoke coverage.
  A further declaration matrix now matches Zig for named by-value function
  types, malformed `void` parameters, arrays and `volatile` POD fields, and
  `static` or `extern` function declarations. The smoke suite checks the
  resulting `prepareNative` and `openNative` error categories. Other C
  declaration and policy combinations still need comparison.
  `openNative` now returns normalized handle and function policies like Zig,
  which lets the public `cdecl` wrapper turn an opaque `Foo **out` result into
  a handle object. A shared native library probe returned `HaoBox 37` from
  both runtimes; the Cyna smoke suite retains the output handle and close path.
  Direct `callNative` failures for an unknown symbol, wrong argument count,
  and a closed library now match Zig's `RuntimeError` name, `invalid_arg` code,
  and `C:` message prefix. A direct Zig/Cyna fixture produced identical lines.
  Native argument conversion now preserves a pending JavaScript exception
  instead of replacing it with `FFI: invalid argument value`. A shared probe
  matched both runtimes for a `Symbol` passed to `f64` and `u64`, and an object
  whose numeric conversion throws. The unsigned fallback now tries a string
  conversion after a failed signed conversion, as Zig does.
  `closeNative` now maps invalid zero, negative, and nonnumeric handles to
  Zig's `RuntimeError invalid_arg C: invalid library handle`. A direct probe
  also matched repeated closes and unknown positive handles.

This document is a source inventory and work list. Passing the current tests
does not close these checks.
