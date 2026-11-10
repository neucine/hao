# Hao Cyna port

This is the Cyna implementation under development. It currently runs JavaScript
and TypeScript modules, resolves relative file imports and ESM package entries,
exposes `std:runtime`, `std:fs`, `std:process`, `std:http`, `std:util`,
`std:plot`, `std:test`, `std:telemetry`, and `std:ffi`, and supports console output,
timers, QuickJS promise jobs, and native addon modules. Remaining Jupyter
features still need to move from the Zig runtime.
The `jupyter --connection-file <file>` command uses the Cyna connection parser
and kernel dispatcher. A native adapter binds the five ZeroMQ sockets, checks
HMAC signatures, and exchanges bounded multipart messages. Basic TypeScript
cells share a persistent QuickJS context. `jupyter install` writes a kernelspec
under the user's Jupyter directory; `HAO_JUPYTER_KERNEL_DIR` overrides that path.
Notebook cells support `std:` and relative static imports. Objects with a
`repr({ mode: "text" })` method can return text or `{ mime, data }`; nontext
results are published as Jupyter `display_data`. Promise results are awaited,
including timer delayed resolution and rejection. Broader rich display parity
is still pending.
Silent notebook requests execute without publishing cell input, streams, or
results and return a null execution count without advancing visible history.
Visible requests with `store_history: false` publish their results without
advancing the execution count.
`user_expressions` evaluate against the persistent notebook context after a
successful cell and return individual result or error entries in the reply.
The kernel replies to completion and inspection requests with empty matches
or inspection data, and serves tail and range history for the 128 most recent
stored notebook cells. Shutdown replies echo the requested restart flag.
Ordinary objects use `std:util.inspect` for their text result.
Top level `const`, `let`, and class declarations can be redefined in later cells.
JavaScript execution errors include their stack in the Jupyter error reply.
The build also produces a Cyna runtime static library with the C API in
`include/hao.h`; the consumer example is `cyna/test/embed_consumer.c`.

`src/runtime.cy` owns the event loop and module registry, `src/fs_host.cy` owns
file access, and `bridge.c` and `fs_bridge.c` adapt QuickJS values to the Cyna
host functions. `readFileSync` uses a 100 MiB limit and fails if the file grows
between sizing and reading.

`src/package_resolver.cy` handles `RUNTIME_PACKAGE_PATH`, ancestor
`node_modules` directories, package `exports` and `main`, and the ESM entry
extension policy. It limits parsed manifests to 256 KiB, disallows entries
containing `..`, and reports unresolved packages through the QuickJS loader.
Addon entries (`.dylib`, `.so`, `.dll`, `.node`) load through the stable ABI in
`include/addon.h`; package specifiers select among modules registered by one
library. Addon metric callbacks and `std:telemetry` share one registry per
runtime.
The Cyna host currently targets macOS arm64.
HTTP download hashing and Jupyter HMAC signatures use OpenSSL 3 through a
shared C adapter.
Startup settings `RUNTIME_QJS_STACK_SIZE`, `RUNTIME_QJS_GC_THRESHOLD`, and
`RUNTIME_LIBUV_THREADPOOL_SIZE` configure QuickJS and libuv before evaluation.
The stack defaults to 8 MiB, matching the Zig runtime. Invalid positive size
settings fail initialization.
At startup, the Cyna host loads an optional `.env` file from the current
directory. Set `DOTENV` to require a specific file, or set it to an empty value
to disable loading. Existing environment values take precedence, and the file
is limited to 1 MiB.

`src/process_host.cy` uses Cyna's process library for `getEnv` and `run`.
The JavaScript API keeps Hao's Promise, `json()`, `text()`, and exit checking
behavior. Options are limited to 1 MiB, `maxOutputBytes` to 16 MiB, and the
captured output is checked against that limit after the child exits. The
current Cyna process result does not expose a terminating signal, so `signal`
is `null` in this port.

Standard module source files are installed beside the executable under
`modules/`. Cyna loads them from the executable directory, and the QuickJS
bridge transpiles TypeScript before compilation. `std:plot` uses Hao's existing
TypeScript source and the Cyna `std:fs` host functions.

`std:http` provides `request`, `get`, `post`, and `download` through a bounded
libcurl adapter. It supports HTTP(S), request headers and bodies, decoded
responses, and up to three redirects. Downloads stream to a temporary file in
the destination directory, hash decoded bytes, and atomically replace the
destination after a successful response. `serve` uses libuv sockets and Hao's
TypeScript HTTP/1.x framing and validation, with bounded bodies, connection
limits, and request deadlines. Client requests and downloads use libuv workers,
so timers and servers continue running during transfers. QuickJS values are
created on the event loop thread after each transfer completes.

`std:test` uses Hao's existing TypeScript assertion and mock APIs with a Cyna
hosted suite registry. Run a file or directory with
`./cyna/build/hao-cyna test [--grep pattern] <file-or-dir>...`. The runner
supports async tests and hooks, skip and only modes, a failing exit status,
reverse cleanup hook order, and blocked suites after failed setup.
Directory discovery selects `.test.ts` files; explicit file paths can have
other names or supported JavaScript/TypeScript extensions. Files run in
lexicographic path order, matching the Zig runner.
`captureOutput` captures `console.log`, `console.error`, and `console.warn`
from callbacks, or runs a child file and captures its process output. Callback
capture is limited to 16 MiB per stream. The runner prints elapsed time and
skip categories; set `RUNTIME_TEST_REPORTER=ansi` for colored case labels.
Further test isolation parity is pending. Test file load failures are counted
separately; registrations made before a file fails to load are discarded,
successfully loaded files still run, and a load failure sets the command's
exit status. The runner loads `std:test` before test files so its automatic
mock cleanup hook survives a failed file import.

`std:telemetry` retains Hao's metric and trace APIs. Metric registration lives
in the C bridge, while bounded trace records live in its standard module. QuickJS memory gauges use
`JS_ComputeMemoryUsage`; `allocator_active_bytes` and `allocator_peak_bytes`
use the macOS malloc zone totals rather than the Zig runtime allocator. Trace
context integration with HTTP workers remains to be ported. `setTimeout`
callbacks retain the trace parent active when scheduled. Set
`RUNTIME_TELEMETRY_CONSOLE=1` to start an in-process console on loopback;
`RUNTIME_TELEMETRY_CONSOLE_PORT` selects the port and defaults to an available
port. The console serves Hao's dashboard, health, metrics, and trace endpoints.
The Cyna trace endpoint retains 512 start and end records with sequence cursors
and reports overwritten history. Span events and attributes remain to be ported.
On glibc Linux, allocator gauges use `mallinfo2`; the peak is the highest
sampled active value.

`std:ffi` binds typed dynamic symbols through libffi, including mixed numeric
argument classes and typed array pointers. The C declaration wrapper supports
direct function declarations, C comments, and pointer plus length buffer policies. Calls
are limited to eight arguments. The C declaration wrapper supports one hidden
pointer output parameter through `returns.out`, including status error policies.
Error policies can call a declared C helper for the message, using a named
argument from the failed call.
Opaque struct typedefs and returned handle policies are supported, including
configured close functions. POD struct pointers stage scalar and nested fields
with C alignment and copy changed fields back to the JavaScript object. C
declarations support `runtime-default`,
`relative-first`, and `system-first` library search strategies with explicit
search directories.
Library searches accept `.dylib` and `.so` names in configured directories.

Builds currently require Apple Silicon macOS, Zig 0.17.0, Cyna
0.5.1-beta.1, Rust, and the Homebrew curl, libffi, zeromq, and openssl@3
libraries. The pinned Cyna beta is not available from the public release
installer yet, so use an installed development distribution of that version.
From the Hao repository root, run `sh cyna/build.sh`, then
`./cyna/build/hao-cyna <file.ts>`. The script builds the QuickJS and Rust
transpiler archives and libuv through `zig build cyna-deps`, builds the Cyna
executable and embedding archive, and installs the module files.
It derives the C header include paths from the pinned QuickJS and libuv hashes
in `build.zig.zon` and creates ignored links under `cyna/.deps/`.
It uses Zig's release mode because its debug QuickJS archive emits sanitizer
symbols that the Cyna linker does not supply.

Run `sh cyna/test/smoke.sh` after building to check TypeScript imports,
`std:runtime`, `std:fs`, `std:process`, `std:plot`, package imports, timers,
queued Promise jobs, and error exit behavior.
