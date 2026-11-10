# Hao Cyna port

This is the Cyna implementation under development. It currently runs JavaScript
and TypeScript modules, resolves relative file imports and ESM package entries,
exposes `std:runtime`, `std:fs`, `std:process`, `std:plot`, and `std:util`, and supports
`console.log`, timers, and QuickJS promise jobs. Native addons, libuv I/O beyond
timers, and the remaining `std:` modules still need to move from the Zig runtime.

`src/runtime.cy` owns the event loop and module registry, `src/fs_host.cy` owns
file access, and `bridge.c` and `fs_bridge.c` adapt QuickJS values to the Cyna
host functions. `readFileSync` uses a 100 MiB limit and fails if the file grows
between sizing and reading.

`src/package_resolver.cy` handles `RUNTIME_PACKAGE_PATH`, ancestor
`node_modules` directories, package `exports` and `main`, and the ESM entry
extension policy. It limits parsed manifests to 256 KiB, disallows entries
containing `..`, and reports unresolved packages through the QuickJS loader.
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
destination after a successful response. The transport currently blocks the
runtime while a request runs. `serve` remains to be ported.

From the Hao repository root, run `sh cyna/build.sh`, then
`./cyna/build/hao-cyna <file.ts>`. The script builds the QuickJS and Rust
transpiler archives, builds the Cyna executable, and installs the module files.
It uses Zig's release mode because its debug QuickJS archive emits sanitizer
symbols that the Cyna linker does not supply.

Run `sh cyna/test/smoke.sh` after building to check TypeScript imports,
`std:runtime`, `std:fs`, `std:process`, `std:plot`, package imports, timers,
queued Promise jobs, and error exit behavior.
