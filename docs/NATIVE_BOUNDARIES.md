# Native language boundaries

The Cyna application owns its public workflow and C ABI exports. `export c(...)` functions remain in their feature modules (`embed.cy`, `fs.cy`, `package.cy`, and `std/process/native.cy`). The public embedding declarations are in `include/hao.h` and `include/addon.h`. Internal C callers of Cyna exports include `src/cyna_exports.h`, which shares the process result layout with `std/process/execute.h`.

Imported C functions have a C implementation, a header declaring its native signature, and a Cyna module containing `extern c(...)` declarations. Callers import that Cyna module instead of redeclaring its symbols. The native pairs are `bridge`, `jupyter/zmq`, `std/process/execute`. The `c_bytes.cy` helpers use Cyna `unchecked` raw pointer operations and have no project C implementation. For feature files whose name already belongs to a Cyna workflow, the extern module uses a suffix: `global/console_native.cy` with `global/console.c/.h`, `global/timer_native.cy` with `global/timer.c/.h`, `telemetry/native.cy` with `telemetry/interface.c/.h`, and `module.cy` with `module.c/.h`. The import spells the reserved filename as `` .`module` `` using Cyna escaped identifiers.

Rust owns TypeScript transpilation in `libs/transpiler`. Its exported C signatures are declared in `libs/transpiler/include/hao_transpiler.h`; `bridge.c` and `module.c` include that header. The bridge performs host runtime and QuickJS integration. It receives validated runtime sizes from `config.cy`; it does not parse startup size settings or own the transpiler implementation.

The Cyna `write` declaration in `stderr.cy` binds the platform C library directly; it has no project C implementation. The native host and QuickJS adapters expose their C to C entry points through adjacent headers, including async loop, filesystem, process, HTTP, FFI, telemetry metrics, addons, errors, and process memory. Their private QuickJS and libuv implementation details remain inside the C files.
The async loop C ABI exports live in `async/uv.cy`. The module imports libuv's loop operations and the shared allocator directly. `async/uv.h` declares the exported signatures for C callers; no project C source implements these functions.

## Why C remains

The current build contains 17 project C sources (4,566 lines). Hao now builds pinned Cyna source revision `e16127d`, which includes the `std.fs.exists` result fix (LG-79) and bounded `std.fs.read_bytes_limited` (LG-82). `fs.cy` and `package.cy` use these APIs. `fs.cy` classifies script read failures using Cyna filesystem errors and path checks. Jupyter connection reads use `std.fs.read_bytes_limited_exact`, which rejects growth after the initially measured bytes. Most remaining C code is native library and QuickJS integration; the table below records roles rather than language blockers.

| C sources | Current role | Blocker status |
| --- | --- | --- |
| `bridge.c`, `module.c`, `errors.c`, `global/console.c`, `global/timer.c`, `js/addon.c` | QuickJS runtime, module loader, callbacks, errors, and addon ABI | C API integration choice; no Cyna impossibility established |
| `std/fs/native.c`, `std/process/native.c`, `telemetry/interface.c`, `telemetry/metrics.c` | QuickJS adapters for standard modules and telemetry | C API integration choice; no Cyna impossibility established |
| `std/ffi/native.c`, `std/http/native.c`, `std/http/server_uv.c`, `jupyter/zmq.c` | libffi, libcurl, libuv, and ZeroMQ calls and callbacks | Native library integration choice; no Cyna impossibility established |
| `std/process/execute.c`, `process_memory.c`, `runtime_allocator.c` | POSIX subprocess and memory accounting, host memory counters, and allocator shared with C libraries | Host implementation choice; no Cyna impossibility established |

The removed `c_bytes.c` only wrapped pointer reads and `memcpy`. `c_bytes.cy` now performs those operations in an audited `unchecked` block. This passed the executable and static library builds, the port smoke suite, and 235 Zig/Cyna native value comparisons. Other C files need a behavior and API review before moving their implementations; this table is an ownership inventory, not a claim that Cyna cannot express their work.
