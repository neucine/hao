# Hao Cyna port

This is the Cyna implementation under development. It currently runs JavaScript
and TypeScript modules, resolves relative file imports, exposes `std:runtime`
and `std:fs`, and supports `console.log`, timers, and QuickJS promise jobs.
Package imports, native addons, libuv I/O beyond timers, and the remaining
`std:` modules still need to move from the Zig runtime.

`src/runtime.cy` owns the event loop and module registry, `src/fs_host.cy` owns
file access, and `bridge.c` and `fs_bridge.c` adapt QuickJS values to the Cyna
host functions. `readFileSync` uses a 100 MiB limit and fails if the file grows
between sizing and reading.

From the Hao repository root, build the existing QuickJS and Rust transpiler archives with
`zig build -Doptimize=ReleaseFast`, then run `cyna check cyna`,
`cyna build cyna`, and `./cyna/build/hao-cyna <file.js>`. The release build
avoids sanitizer symbols emitted by Zig's debug QuickJS archive, which the
Cyna linker does not supply.

Run `sh cyna/test/smoke.sh` after building to check TypeScript imports,
`std:runtime`, `std:fs`, timers, queued Promise jobs, and error exit behavior.
