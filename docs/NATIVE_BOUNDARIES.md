# Native language boundaries

The Cyna application owns its public workflow and C ABI exports. `export c(...)` functions remain in their feature modules (`embed.cy`, `fs.cy`, `package.cy`, and `std/process/native.cy`). The public embedding declarations are in `include/hao.h` and `include/addon.h`. Internal C callers of Cyna exports include `src/cyna_exports.h`, which shares the process result layout with `std/process/execute.h`.

Imported C functions have a C implementation, a header declaring its native signature, and a Cyna module containing `extern c(...)` declarations. Callers import that Cyna module instead of redeclaring its symbols. The native pairs are `bridge`, `fs_limit`, `jupyter/zmq`, `std/process/execute`, and `c_bytes`. For feature files whose name already belongs to a Cyna workflow, the extern module uses a suffix: `global/console_native.cy` with `global/console.c/.h`, `global/timer_native.cy` with `global/timer.c/.h`, `telemetry/native.cy` with `telemetry/interface.c/.h`, and `module_ffi.cy` with `module.c/.h`.

Rust owns TypeScript transpilation in `libs/transpiler`. Its exported C signatures are declared in `libs/transpiler/include/hao_transpiler.h`; `bridge.c` and `module.c` include that header. The bridge performs host runtime and QuickJS integration. It does not own the transpiler implementation.

The Cyna `write` declaration in `main.cy` binds the platform C library directly; it has no project C implementation. Other native host and QuickJS adapters still use internal C declarations where no Cyna import crosses that boundary.
