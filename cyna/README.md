# Hao Cyna port

This is the Cyna implementation under development. It currently runs plain
JavaScript scripts with `console.log` and drains QuickJS promise jobs. Module
loading, TypeScript transpilation, libuv integration, and `std:` modules still
need to move from the Zig runtime.

The C bridge isolates the QuickJS C ABI while Cyna owns the CLI and file input.
From the Hao repository root, build the existing QuickJS archive with
`zig build -Doptimize=ReleaseFast`, then run `cyna check cyna`,
`cyna build cyna`, and `./cyna/build/hao-cyna <file.js>`. The release build
avoids sanitizer symbols emitted by Zig's debug QuickJS archive, which the
Cyna linker does not supply.
