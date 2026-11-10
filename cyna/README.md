# Hao Cyna port

This is the Cyna implementation under development. It currently runs JavaScript
and TypeScript modules, resolves relative file imports, exposes `std:runtime`,
supports `console.log`, timers, and QuickJS promise jobs. Package imports,
native addons, libuv based I/O beyond timers, and the remaining `std:` modules
still need to move from the Zig runtime.

The C bridge isolates the QuickJS C ABI while Cyna owns the CLI and file input.
From the Hao repository root, build the existing QuickJS and Rust transpiler archives with
`zig build -Doptimize=ReleaseFast`, then run `cyna check cyna`,
`cyna build cyna`, and `./cyna/build/hao-cyna <file.js>`. The release build
avoids sanitizer symbols emitted by Zig's debug QuickJS archive, which the
Cyna linker does not supply.

Run `sh cyna/test/smoke.sh` after building to check TypeScript imports,
`std:runtime`, timers, queued Promise jobs, and error exit behavior.
