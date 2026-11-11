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
The 18 legacy `std/**/*.d.ts` declarations and all 12 legacy TypeScript source
and asset files now have matching port locations. The inventory checks them;
it requires byte identity for all except the HTTP index split and TypeScript
configuration described above.
TypeScript 5.9.3 checks the port's modules and declarations with the port's
`src/tsconfig.json`. The port config adds its separate HTTP server module and
telemetry paths and uses the shared QuickJS host declarations.

The package loader now carries resolution failure categories across the Cyna
boundary. A shared fixture matched Zig's stderr and exit status for missing
packages, manifests, exports, invalid JSON, CommonJS packages, non ESM entries,
missing entry files, and relative source files. The smoke suite retains this
diagnostic matrix. The module loader now sets the same error when an imported
source is oversized or resolves to a directory; it previously returned with
an unset QuickJS exception and printed `[uninitialized]`.

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

A shared CLI argument probe matched `--version`, missing arguments, and invalid
Jupyter subcommands. It found that bare `hao test` and a missing `--grep` value
used Cyna stdout messages instead of Zig's usage on stderr with status 2; those
now match. An empty test directory now runs successfully with zero tests, as
Zig does. Missing and oversized script files now report Zig's `FileNotFound`
and `StreamTooLong` messages on stderr. Both runtimes accept trailing arguments
after `jupyter install`.
The test reporter now writes its file counts, case results, suite indentation,
skip reasons, and summary to stderr in Zig's layout. A direct plain reporter
probe with passing and skipped cases, plus a failing case probe, matched Zig's
output structure; measured durations naturally differed. The smoke suite also
checks the empty directory summary on stderr. A direct file load failure probe
found that Cyna discarded tests registered before the exception, while Zig ran
them. Cyna now retains those registrations and reports the failed module and
exception message on stderr. The smoke suite checks a partially loaded suite
whose hook fails during the subsequent run. Complex hook combinations still
need direct reporter comparisons.
The failed module glyph now uses Zig's red ANSI style when the reporter is in
ANSI mode; the smoke suite checks plain and ANSI modes separately.
Output capture now grows with the captured stream. A shared 18 MB probe
returned the full 18,000,000 bytes on Zig while Cyna previously threw at its
16 MiB cap; the smoke suite retains the large capture case.
A malformed TypeScript test file now exits after Zig's `TranspileFailed` line,
without a test summary; the smoke suite retains this fatal load path.
An oversized test file similarly exits with `StreamTooLong` and no summary,
matching a direct Zig/Cyna comparison at the 10 MiB read limit.
A shared nested hook fixture showed that Zig records a failed `beforeAll` as
one suite failure, skips every selected case in that suite, runs its `afterAll`
before a sibling case, and still runs the enclosing `afterAll`. The Cyna runner
now walks suites in that order. The direct plain reporter output and stdout
hook order matched Zig, apart from measured durations. The smoke suite checks
the failure and skip totals for a blocked suite and partial `beforeEach` setup.
A shared fixture with two failing `afterEach` hooks, a `null` test throw, and a
failing `afterAll` now matches Zig's hook execution and failure lines. Cyna
runs every cleanup hook in reverse order, retains the first failure as the case
failure, and reports later cleanup failures separately. The smoke suite keeps
this combination as a regression case.
A nested hook comparison also matched Zig's event order when both inner cases
fail in `beforeEach` and an outer sibling passes. Both runtimes ran outer
`afterEach` after each failed setup, then inner `afterAll` before the sibling,
and finally outer `afterAll`. The smoke suite retains this ordering and the
one passed, two failed reporter totals.

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
  runtimes. An option edge matrix found that Zig clamps `NaN` to zero and
  treats both signs of infinity and values above `usize` capacity as unlimited;
  Cyna previously fell back to its default for `NaN` and clamped negative
  infinity to zero. The port now matches Zig's `inspect` output and
  `getInspectOptions` values for those cases, with smoke coverage. A further
  shared probe found that throwing `repr` getters, object field getters,
  array-like `toString`, and proxy `ownKeys` escaped from Cyna's formatter,
  whereas Zig produced an empty value or empty object. Cyna now matches the
  Zig output for these cases, including a `repr` result whose data is a
  `Symbol`; the smoke suite retains representative errors.
  Zig's `maxStringLength` measures UTF-8 bytes. A shared matrix of accented,
  CJK, and emoji strings at multiple limits exposed Cyna's UTF-16 unit count;
  Cyna now truncates by UTF-8 bytes and emits a replacement character for each
  byte cut from an incomplete character. An unpaired surrogate also counts as
  three UTF-8 replacement bytes while retaining the original string if the
  limit does not truncate it. The smoke suite checks representative limits.
  A throwing option getter is ignored by Zig while later numeric limits are
  still read. Cyna now catches each getter separately; a direct inspect and
  `setInspectOptions` probe matches Zig's output and defaults.
  A further shared probe matched Zig's two reads of a `repr` getter, fallback
  for a throwing function `name` getter, and the distinct paths for throwing
  `dtype`, `shape`, and `toString` getters during array-like detection. The
  smoke suite retains the output and getter count.

- The `std:fs` surface has matching public operations in the shared end to end
  suite: existence, read, write, and size. A direct Zig/Cyna comparison also
  matched file, symlink, missing path, and directory results. The smoke suite
  covers NUL truncation and the 100 MiB read limit. The Cyna file reader now
  sizes and reads through one open handle, as Zig does, so a separate `stat`
  call cannot race a subsequent open. It reads the initially sized content
  when a file grows during the read, matching Zig's read path. Concurrent
  mutation during a read has not been exercised directly.
  A direct unreadable file probe found that Zig's `statSync` fails because it
  opens the file before measuring its size, while Cyna's use of `stat` returned
  the size. Cyna now opens and seeks the file like Zig, and the smoke suite
  checks the permission error under a non-root user.
  An argument conversion matrix found that QuickJS conversion failures leaked
  through Cyna's `std:fs` adapter, while Zig reports each operation's expected
  path or data `TypeError`. Cyna now consumes the conversion exception and
  reports Zig's error for Symbols and throwing `toString` methods.
  A path component of 256 bytes made the pinned Cyna `std.fs.exists` return a
  typed error through Hao's exported Cyna function and crashed in
  `failure_trace.c:25`; Zig's `existsSync` returns `false`. Hao now performs
  this Boolean existence check in its C adapter and exports it through
  `fs.cy`. The smoke suite covers 256 and 1023 byte names. The cause is now
  confirmed in Cyna's LLVM return conversion: it copied the scalar C result
  into a larger result without initializing trace metadata, then released the
  uninitialized handle on the error path. Cyna branch
  `codex/hao-fs-result-bridge` fixes this in `a05414d` and passes its native
  regression and C ABI suite. Hao retains the adapter while pinned to the
  installed 0.5.1-beta.1 compiler.

- The `std:process` native boundary matched Zig in a direct matrix covering
  malformed options, argument arrays, working directories, output limits,
  exit codes, and environment lookup. The smoke suite now retains the
  representative option errors alongside its existing subprocess and NUL
  cases. A shared options getter probe now observes Zig's `cmd`, `args`, `cwd`,
  `maxOutputBytes` access order under Cyna too. Conversion failures for these
  four options now use Zig's public `TypeError` messages. The Cyna console
  preserves the embedded NUL in a printed input label where Zig truncates it;
  both lookups return the same environment value.
  `getEnvNative` now reports Zig's variable name `TypeError` for a `Symbol` or
  throwing `toString`, rather than exposing the JavaScript conversion error.

- The `async/loop.zig` turn boundary has a direct port in `async/loop.cy` and
  `async/uv.c`: both check `uv_loop_alive` before `UV_RUN_ONCE` and report a
  serviced turn even when its final handle closes. `Loop.run_until_idle` also
  drains QuickJS jobs between turns.
  The remaining Zig `Loop` methods have explicit implementation locations:
  loop allocation, deinitialization, and nonblocking runs are in
  `async/uv.c`; current-loop ownership is the `HaoRuntime` handle in
  `bridge.c` and `runtime_host.h`; timer start, cancellation, one-shot fire,
  and close callbacks are in `global/timer.c`; HTTP worker requests use
  libuv from `std/http/native.c`. Zig's `async/uv.zig` FFI declarations are
  replaced by the libuv header included at these C boundaries.
  The smoke suite covers timer cancellation,
  callback errors, and a Promise job between two timer callbacks. This checks
  the timer path. A shared nested timer probe additionally matched cancellation,
  Promise job draining, and scheduling a new timer inside a callback. Other
  libuv handle types and shutdown ordering still need comparison. A callback
  failure followed by a pending timer now matches Zig's stderr bytes and exits
  before the second timer fires. The port prints the exception message and
  stack once. The native timer context path avoids adding an internal wrapper
  frame. The smoke suite retains this case.
  Draining Promise jobs inside a timer callback exposed a later timer firing
  before an unhandled rejection reached the host. The timer now stops the
  libuv turn when job draining records a rejection or callback error. A shared
  rejection fixture exits before the later timer and matches Zig's stdout and
  stderr bytes; the smoke suite retains it.
  A shared script combined an in-process libuv HTTP server and client, a
  subprocess, an independent timer, and a Promise continuation in the server
  handler. Three runs of each binary produced identical output and completed
  with status zero. The smoke suite retains completion and event membership
  checks without depending on OS scheduling order.
  A shutdown probe now waits until an HTTP handler has entered, then throws
  from a timer while the handler, client, and another timer remain pending.
  Three direct runs of each binary matched exit status, stdout, and stderr:
  the handler entry prints once and no later callback runs. The smoke suite
  retains this active-handle failure path.
  A same-turn probe found that draining Promise jobs inside a timer callback
  reordered timers from Zig's `first,second,job` to `first,job,second` when a
  trace span was active. A tracked patch to QuickJS now captures trace context
  on job enqueue and restores it while that job executes. Timer callbacks no
  longer drain jobs themselves. Both ordinary and traced same-turn probes
  match Zig's order, while the interleaved trace probe retains child parentage.
  A timer argument matrix found that Zig silently ignores a `clearTimeout`
  ID whose numeric conversion fails, including a `Symbol` and a throwing
  `valueOf`. Cyna now consumes that conversion exception and returns
  `undefined`, while `setTimeout` still propagates invalid delay errors.
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
  captures context before the deferred native request and enters it while the
  worker completion resolves or rejects its Promise. QuickJS captures that
  context for each queued continuation, so completion leaves job scheduling to
  the normal loop drain. The simple fixture
  and a smoke case with two concurrent requests and a rejected request now
  produce parented child spans. Further scheduling combinations remain part
  of the full parity audit.
  A telemetry console probe with two overlapping async traces revealed that
  Cyna's JavaScript timer wrapper restored context before Promise continuation
  jobs ran: both child spans became roots. The native timer now captures the
  trace context when scheduled and enters it for the callback. QuickJS retains
  the context for its queued jobs. Both Cyna child spans now reference their own
  parent span and trace ID; the smoke suite checks that relationship. Zig's
  global context nests the second parent under the first in this overlap, so
  Cyna's independent parent traces are retained as the clearer behavior.
- The shared HTTP server consumer passed under both runtimes for Unicode and
  binary bodies, JSON requests, HEAD, handler and header errors, recovery after
  errors, and eight concurrent POST requests with independent bodies. The
  concurrent probe exercises multiple live connections while each handler
  awaits a timer. The same consumer now closes the server from an active
  handler, verifies that the client disconnects, then waits for the handler's
  pending timer to settle. The consumer now also holds an incomplete POST
  request open while the handler closes the server; both runtimes close that
  socket without a response and exit successfully with the same output order.
  Raw socket probes under both runtimes matched rejection statuses
  for missing Host, duplicate Content-Length, chunked transfer encoding,
  Expect, oversized body declaration, and oversized headers. Both served only
  the first of two pipelined requests before closing the connection. A second
  shared framing matrix matched HTTP/1.0 without Host; duplicate and empty
  Host; folded headers; malformed method and version; Content-Length spacing,
  signs, and conflicts with Transfer-Encoding. The deterministic cases are in
  the server consumer. A further raw request matrix matched Zig's exact
  responses for absolute URI rejection, request line spacing, tab separators,
  host header whitespace, duplicate ordinary headers, leading zero and trailing
  tab content lengths, non-ASCII host bytes, lowercase methods, `OPTIONS *`,
  and bare carriage return rejection. The deterministic cases are retained in
  the server consumer. Other protocol framing and shutdown cases remain open.
  A raw response comparison also matched every byte for GET and HEAD success,
  HTTP/1.0 success, missing Host, Expect rejection, handler failure, and an
  empty JSON POST failure. The shared server consumer retains exact response
  checks for the first four cases.
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
  For `silent`, `store_history`, and a shutdown `restart` request, Cyna follows
  the Jupyter protocol while Zig ignores those fields. These are deliberate
  behavior extensions, retained by the Cyna kernel consumer. A shared probe
  found that Zig still dispatches `kernel_info_request` and `shutdown_request`
  when their content is malformed JSON, while Cyna discarded them before
  dispatch. Cyna now uses empty content for that case; the same probe passes
  under both binaries.
  A reduced kernel probe sent a `shutdown_request` with one corrupted HMAC
  digit before a valid `kernel_info_request`. Zig shut down and the shared
  consumer failed with status 70; Cyna ignored the forged shutdown and answered
  the valid request. Zig's `wire.recvMessage` parses the signature frame but
  does not verify it against the connection key; it signs outbound messages
  only. Cyna's inbound validation is retained as a security improvement, and
  the Cyna kernel consumer now checks recovery after the forged control request.
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
  The shared kernel consumer now also sends a binary heartbeat containing an
  embedded NUL before the shell requests. Both runtimes echo the exact three
  bytes and continue through the shared execution and shutdown sequence.
  Notebook cells now use Zig's `__hao_kernel_cell_<execution_count>.ts`
  filename under the kernel working directory. The shared error probe checks
  that both runtimes report this filename in a cell stack. The Cyna bridge
  resolves relative cell filenames before transpilation and evaluation, so
  relative module imports continue to use the cell directory.
- Compare FFI declaration, marshaling, handle lifecycle, and error cases beyond
  the existing C ABI and direct binding cases.
  A direct `std:ffi/native` fixture passed under both runtimes: opening libc,
  calling `getpid`, closing twice, and calling after close produced the same
  result types and `TypeError FFI: library has been closed`. The Cyna smoke
  fixture now checks a successful call before the duplicate close. The shared
  FFI end to end suite passes 4 Zig cases and 7 Cyna cases; three added Cyna
  cases cover invalid declarations and multiline type parsing. These checks
  do not cover all marshaling widths or C ABI policy combinations.
  A shared libc probe matched `cstring` argument byte lengths for accented and
  emoji text, `strcmp` ordering, and nullable `cstring` returns from `getenv`.
  The smoke suite retains these direct FFI conversions.
  With native stacks enabled, a direct error matrix found that Cyna used a
  generic `Error` for invalid `std:ffi/native` descriptor arguments and return
  types, while Zig reports distinct `TypeError` messages. Cyna now validates
  these fields after opening the library, matching Zig's error order. Direct
  `std:ffi/c/native` call and close handle errors no longer receive a
  `nativeStack` that Zig leaves undefined. The smoke suite retains these paths.
  A malformed function descriptor that is not an object yields Zig's
  `[uninitialized]` exception value, while Cyna reports a descriptive
  `TypeError`. Zig also accepts bindings above eight arguments and `void`
  arguments during open, although its call trampoline has an eight-argument
  bound; Cyna rejects those unsupported bindings during open. These are
  deliberate error and bounds improvements, not claims of identical behavior.
  The direct `std:ffi/native` name matrix now matches Zig's conversion of
  `undefined`, `null`, empty text, numbers, booleans, and objects before opening
  a library. Symbol and throwing string conversion report Zig's library-name
  `TypeError`; a convertible object can open libm. The smoke suite retains
  these cases.
  A separate C library probe compared `u64` arguments and returns at 2^53,
  2^63, and `UINT64_MAX` under both runtimes. The observed JavaScript numbers,
  including rounding above 2^53, matched. The Cyna smoke fixture now retains
  the `UINT64_MAX` and 2^53 + 1 checks.
  A shared C width probe matched `i8` and `u8` argument truncation and returns.
  For `f32`, Cyna returns the correctly rounded float value
  `1.100000023841858` from `hao_echo_f32(1.1)`, while Zig's current trampoline
  returns `1.273197475e-314`. The Cyna smoke suite now retains this ABI check;
  the correct `f32` result is an intentional improvement over Zig's bug.
  An extended unsigned input probe matched positive values, truncation, and
  Symbol or throwing-object conversion errors. For `-1`, Zig silently returns
  `undefined` because its unsigned conversion fails without setting a JavaScript
  exception; Cyna throws `TypeError: FFI: invalid argument value`. The explicit
  error is retained as an intentional improvement and has smoke coverage.
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
  A shared `prepareNative` matrix covering search options, status policy,
  inferred handle output, and buffer policy produced identical stdout on both
  runtimes. A broader shared fixture matched through recursive POD declaration
  preparation, then Zig exited with status 139 while Cyna reported
  `RuntimeError invalid_arg C: unsupported POD struct layout for runtime
  marshaling`. A reduced case confirmed both runtimes open and close the
  recursive declaration successfully; Zig crashes on `callNative` with
  `{ f: {} }`, while Cyna returns that structured error and exits normally.
  The Cyna behavior avoids a host crash; its smoke suite covers this path.
  Four further unchanged smoke fixtures ran under both binaries with identical
  exit status, stdout, and stderr: policy errors, options purity, declaration
  syntax, and named types. The tail of the broader preparation fixture also
  matched after isolating it from Zig's recursive POD crash. These checks
  cover the listed declaration and policy cases, while native call combinations
  outside those fixtures remain open.
  A shared native call sweep of the smoke fixtures found one additional safe
  mismatch: the default status policy message was `C: native call failed` in
  Zig and `<symbol> failed` in Cyna. Cyna now uses Zig's default. The sweep also
  reproduced the documented Zig mixed integer/float rejection, float return
  bug, negative unsigned conversion, and policy validation crash. The other
  native fixtures in that sweep matched exit status, stdout, and stderr.
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
