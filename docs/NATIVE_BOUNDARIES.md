# Native language boundaries

Hao's Cyna application lives in `src/` at the legacy feature paths. All 36 Cyna C ABI exports are declared in `src/hao_abi.cy`. Each export delegates to a public function in its feature module; those modules own the implementation. The executable imports the ABI module, and the static library uses it as its entry module. Public embedding declarations remain in `include/hao.h` and `include/addon.h`.

All project C sources live directly under `src/bridge/`. There are four C translation units, one for each native surface:

| C unit | Owning surface |
| --- | --- |
| `qjs.c` | QuickJS values and callbacks, module loading, console, timers, addon ABI, FFI, filesystem, HTTP, process, notebook cells, and test hooks. |
| `support.c` | Hao allocation accounting, process execution, and process memory counters. |
| `jupyter.c` | ZeroMQ transport, multipart framing, and Jupyter HMAC verification. |
| `telemetry.c` | Telemetry metrics, host memory gauges, native spans, records, and JavaScript telemetry callbacks. |

The Cyna import facades name the foreign contracts:

| Cyna facade | C implementation | Ownership |
| --- | --- | --- |
| `qjs.cy` | `qjs.c` | QuickJS-facing adapters and JavaScript callbacks. |
| `host.cy` | `support.c` | Platform services absent from the pinned Cyna std: tracked allocation, bounded binary process capture, signal status, and process memory counters. |
| `jupyter.cy` | `jupyter.c` | ZeroMQ sockets and frames with HMAC. |
| `telemetry.cy` | `telemetry.c` | Native telemetry storage and callbacks. |
| `transpiler.cy` | No project C wrapper | Cyna declares the existing Rust archive ABI directly. QuickJS integration calls it from `qjs.c`. |
| `uv.cy` | No project C wrapper | Cyna declares the libuv entry points directly. `async/uv.cy` owns loop operations. |

The C boundary exists for four concrete reasons:

- QuickJS exposes a C API and invokes C callbacks.
- The Rust transpiler already exports a C ABI.
- libuv callbacks and the pinned Cyna std leave gaps for bounded binary process output, process memory counters, libcurl, ZeroMQ, libffi, and file size queries.
- QuickJS-facing native libraries need one consistent allocation and lifetime boundary.

This list is a review threshold, not a claim that every capability must remain in C. A new C unit needs a distinct foreign ABI or lifecycle that cannot be owned cleanly by one of these four surfaces. A missing Cyna API is recorded and assessed in the Cyna language-gaps ledger before the project expands the C boundary.

Bridge headers are flat, with no semantic subdirectories. They remain only for declarations shared by C translation units, Cyna exports called from C, or native consumer tests: `runtime.h`, `support.h`, `telemetry.h`, `uv_bridge.h`, and `cyna_exports.h`. Header files contain declarations and shared type definitions only; implementation code, including private helpers such as HMAC verification, stays in its owning `.c` file. The public embedding and addon contracts are in `include/hao.h` and `include/addon.h`.

The allocator boundary has a concrete ownership reason. Zig's `runtime_allocator.zig` wraps its backing allocator and counts Hao-owned Zig allocations. In the Cyna port, native adapters use `hao_alloc` and its accounting header; `runtime_allocator.cy` exposes that allocator to Cyna callers. QuickJS uses its own allocator and is reported separately. Moving only the counters into Cyna would split allocations from their corresponding frees and change the reported scope. This is a Hao runtime allocator contract, not evidence that Cyna std needs a new allocator API. Zig resets its global counters when initializing a runtime. `support.c` keeps process-wide counters across embedded runtime creation because those runtimes can overlap and free allocations after another runtime is created.

`qjs.c` owns the QuickJS error callback, stack capture, runtime lifetime, evaluation, rejection handling, generic and test job drains, notebook cell translation and settling, console and timer installation, module loading, addon loading, filesystem/process/HTTP/FFI adapters, and telemetry callbacks installed into QuickJS.

Cyna owns HTTP URL and server limit policy (`std/http/native.cy`, `std/http/server_uv.cy`), FFI descriptor and decimal pointer policy (`std/ffi/native.cy`), metric policy (`telemetry/metrics.cy`), filesystem limits and recursive directory creation (`fs.cy`), package resolution (`package.cy`), notebook declaration rewriting (`jupyter/cell.cy`), runtime configuration (`config.cy`), and process result conversion (`std/process/native.cy`). `async/uv.cy` calls libuv loop entry points through `bridge/uv.cy`. Feature modules import bridge declarations and keep application policy in Cyna.

`module.cy` owns lexical absolute path normalization and relative import path assembly for QuickJS imports. It uses Cyna `std.process.cwd()` and byte-level path components. The C bridge receives an owned C string through the sole export module, then copies it into a QuickJS allocation for the module loader callback. Source files are read through `std.fs.read_bytes_limited`; C retains only the transpiler call and QuickJS module creation.

For Jupyter, `bridge/jupyter.cy` declares the ZeroMQ adapter ABI. `jupyter/zmq.cy` converts `Connection` and string values to and from that ABI, and `jupyter/wire.cy` exposes the wire handle and its operations to the kernel. `jupyter.c` owns sockets, multipart frames, and the static HMAC helper because the pinned Cyna std has no corresponding native APIs.

The source inventory checks that `cyna.toml` and `cyna.lib.toml` list exactly the four shared C sources, that every other Cyna manifest selects a subset of those sources, that no C source exists outside `src/bridge/`, that Cyna ABI exports remain centralized in `src/hao_abi.cy`, and that raw extern declarations remain in bridge facade files. That inventory proves layout and boundary constraints; it does not by itself prove behavioral parity.
