# Native language boundaries

Hao's Cyna application lives in `src/` at the legacy feature paths. All 36 Cyna C ABI exports are declared in `src/hao_abi.cy`. Each export delegates to a public function in its feature module; those modules own the implementation. The executable imports the ABI module, and the static library uses it as its entry module. Public embedding declarations remain in `include/hao.h` and `include/addon.h`.

All project C sources and internal headers live under `src/bridge/`. Its Cyna import modules name the actual foreign surfaces: `qjs.cy` for QuickJS host calls, `transpiler.cy` for the Rust archive C ABI, `host.cy` for platform services, `uv.cy` for libuv, `jupyter.cy` for ZeroMQ, and `telemetry.cy` for native telemetry callbacks. Feature modules import these declarations and keep their behavior in Cyna. The legacy same stem modules `async/uv.cy`, `jupyter/zmq.cy`, `module.cy`, and `runtime_allocator.cy` remain normal Cyna callers of the bridge. The C declarations of Cyna exports used internally are in bridge headers, including `src/bridge/cyna_exports.h`. Headers exist for interfaces shared across C translation units, across C and Cyna, or with native consumer tests; private implementation details stay in their C sources.
The C boundary is limited to three kinds of work:

| Surface | Files | Why the C boundary remains |
| --- | --- | --- |
| QuickJS host integration | `runtime.c`, `module.c`, `errors.c`, `global/console.c`, `global/timer.c`, `js/addon.c`, `jupyter/cell.c`, `test/runner.c`, `std/fs/native.c`, `std/process/native.c`, `std/http/native.c`, `std/http/server_uv.c`, `std/ffi/native.c`, `telemetry/interface.c`, `telemetry/metrics.c` | QuickJS values, callbacks, module loading, and runtime ownership cross its C API. Application policy is in Cyna and TypeScript feature modules. |
| Rust transpiler calls | `runtime.c`, `module.c`, `jupyter/cell.c` | These call the existing Rust archive through `libs/transpiler/include/hao_transpiler.h`. Rust owns TypeScript transformation. |
| Host and native APIs absent from Cyna std | `runtime_allocator.c`, `process_memory.c`, `std/fs/native.c`, `std/process/execute.c`, `std/http/native.c`, `std/http/server_uv.c`, `std/ffi/native.c`, `jupyter/zmq.c` | The port needs shared allocation counters, macOS memory counters, file size for `statSync`, bounded binary process capture and signal status, libcurl, libuv HTTP callbacks, libffi call layouts, and ZeroMQ frames with HMAC. The pinned Cyna std has bounded file reads and writes but no file size query. It has `std.process.command().output()`, but its `Output` exposes text streams and exit code rather than Hao's bounded byte streams and signal result. No claim of language impossibility is made for these integrations. |

The bridge translation units are grouped by the Cyna facade that consumes
them. This is the ownership boundary; directories are an implementation detail
inside that boundary.

| Cyna facade | Bridge units | Ownership |
| --- | --- | --- |
| `qjs.cy` | `runtime.c`, `module.c`, `errors.c`, `global/`, `js/addon.c`, `jupyter/cell.c`, `test/runner.c`, `std/*/native.c`, `std/http/server_uv.c`, `telemetry/` | QuickJS values, installed callbacks, module loading, notebook packet construction, test hooks, and JavaScript-facing native adapters. |
| `transpiler.cy` | `runtime.c`, `module.c`, `jupyter/cell.c` | The Rust archive remains the source transformer; these units own its call sites and free its returned buffers. |
| `host.cy` | `runtime_allocator.c`, `process_memory.c`, `std/process/execute.c` | Process-wide allocation accounting and platform services without a matching pinned Cyna API. |
| `uv.cy` | No project C wrapper | Cyna calls the libuv ABI directly. `async/uv.cy` owns loop operations. |
| `jupyter.cy` | `jupyter/zmq.c` | ZeroMQ socket and frame handling. `jupyter/cell.c` is QuickJS evaluation and is therefore exposed through `qjs.cy`. |
| `telemetry.cy` | `telemetry/interface.c`, `telemetry/metrics.c` | Native record storage and JavaScript access to telemetry metrics. |

A source can appear in more than one row because one adapter crosses more than one native API. The current build compiles 19 project C sources. The bridge is split by owning lifecycle: `runtime.c` owns QuickJS lifetime, evaluation, rejection handling, generic job draining, and the embedding error channel; `jupyter/cell.c` owns notebook transpilation, async settling, result formatting, and cell packet construction; `test/runner.c` owns test globals, failure reporting, and the test-specific job drain. `runtime_internal.h` exposes the shared error printer only within the bridge. `src/bridge/jupyter/crypto.h` is shared by the native ZeroMQ adapter and its C consumer tests. `src/bridge/runtime_allocator.c` also supplies allocation statistics to telemetry and shares allocations with QuickJS and native libraries.
The source inventory checks that both `cyna.toml` and `cyna.lib.toml` list exactly those 19 C sources under `src/bridge/`, with no duplicate or uncompiled project C source.

The allocator boundary has a concrete ownership reason. Zig's `runtime_allocator.zig` wraps its backing allocator and counts Hao-owned Zig allocations. In the Cyna port, the native adapters use `hao_alloc` and its accounting header; `runtime_allocator.cy` exposes that allocator to Cyna callers. QuickJS uses its own allocator and is reported separately. Moving only the counters into Cyna would split allocations from their corresponding frees and change the reported scope. This is a Hao runtime allocator contract, not evidence that Cyna std needs a new allocator API.
Zig resets its global counters when initializing a runtime. The C bridge keeps
process wide counters across embedded runtime creation because those runtimes
can overlap and free allocations after another runtime is created. The smoke
suite runs the native allocator test for alignment, allocation, resize, free,
and counter accounting.

`errors.c` is a QuickJS callback adapter: it installs a `JS_NewCFunction` callback, reads the runtime's stack-trace setting from the QuickJS context, captures native frames with `backtrace`, and returns a QuickJS string. `errors.cy` owns the JavaScript `RuntimeError` definition and installation sequence. The native frame capture is platform work at the QuickJS boundary; no Cyna std expansion follows from this adapter alone.

Cyna owns HTTP URL and server limit policy (`std/http/native.cy`, `std/http/server_uv.cy`), FFI descriptor and decimal pointer policy (`std/ffi/native.cy`), metric policy (`telemetry/metrics.cy`), filesystem limits and recursive directory creation (`fs.cy`), package resolution (`package.cy`), notebook declaration rewriting (`jupyter/cell.cy`), runtime configuration (`config.cy`), and process result conversion (`std/process/native.cy`). `async/uv.cy` calls libuv loop entry points through `bridge/uv.cy`. The source inventory verifies that all legacy Zig paths have a Cyna or documented layout port and that C sources stay under `src/bridge/`; that inventory alone does not prove behavioral parity.
`module.cy` owns lexical absolute path normalization and relative import path
assembly for QuickJS imports. It uses Cyna `std.process.cwd()` and byte level
path components. The C bridge receives an owned C string through the sole
export module, then copies it into QuickJS allocation for the module loader
callback. Source files are read through `std.fs.read_bytes_limited`; C retains
only the transpiler call and QuickJS module creation.

For Jupyter, `bridge/jupyter.cy` declares the raw ZeroMQ adapter ABI. `jupyter/zmq.cy` converts `Connection` and string values to and from that ABI, and `jupyter/wire.cy` exposes the wire handle and its operations to the kernel. The C adapter owns ZeroMQ sockets, multipart frames, and HMAC because the pinned Cyna std has no corresponding native APIs.
