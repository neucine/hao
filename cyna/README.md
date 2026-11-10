# Hao Cyna port

This is the Cyna implementation under development. It currently runs JavaScript
and TypeScript modules, resolves relative file imports and ESM package entries,
exposes `std:runtime`, `std:fs`, `std:process`, `std:http`, `std:util`,
`std:plot`, `std:test`, `std:telemetry`, and `std:ffi`, and supports console output,
timers, QuickJS promise jobs, and native addon modules. The telemetry console
and Jupyter integration still need to move from the Zig runtime.

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
library. The callback value and collection APIs work, while addon metric
callbacks currently return failure.
The Cyna host currently targets macOS arm64.

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
supports async tests and hooks, skip and only modes, and a failing exit status.
`captureOutput` captures `console.log`, `console.error`, and `console.warn`
from callbacks, or runs a child file and captures its process output. Callback
capture is limited to 16 MiB per stream. The original runner's reporting and
isolation behavior remain to be ported.

`std:telemetry` retains Hao's metric and trace APIs. Metric registration and
bounded trace records live in its standard module. QuickJS memory gauges use
`JS_ComputeMemoryUsage`; `allocator_active_bytes` and `allocator_peak_bytes`
use the macOS malloc zone totals rather than the Zig runtime allocator. Trace
context integration with timers and HTTP workers, plus the telemetry console,
remain to be ported.

`std:ffi` binds typed dynamic symbols through libffi, including mixed numeric
argument classes and typed array pointers. The C declaration wrapper supports
direct function declarations and pointer plus length buffer policies. Calls
are limited to eight arguments. Opaque struct handles, out parameters, POD
structs and custom library search policies remain to be ported.

From the Hao repository root, run `sh cyna/build.sh`, then
`./cyna/build/hao-cyna <file.ts>`. The script builds the QuickJS and Rust
transpiler archives, builds the Cyna executable, and installs the module files.
It uses Zig's release mode because its debug QuickJS archive emits sanitizer
symbols that the Cyna linker does not supply.

Run `sh cyna/test/smoke.sh` after building to check TypeScript imports,
`std:runtime`, `std:fs`, `std:process`, `std:plot`, package imports, timers,
queued Promise jobs, and error exit behavior.
