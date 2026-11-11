# Releasing Hao

The `main` branch contains the Cyna implementation. Its version is recorded in
`cyna.toml`, `cyna.lib.toml`, `cyna.jupyter-connection.toml`, and the CLI
version output. Keep those
values together when preparing a release.

Before tagging, build and verify on Apple Silicon macOS with Cyna
`0.5.1-beta.1` installed:

```sh
sh build.sh
cyna check .
cyna check cyna.lib.toml
cyna check cyna.jupyter-connection.toml
sh test/port/smoke.sh
./build/hao-cyna test test/e2e
```

The build fetches pinned QuickJS and libuv archives, checks their SHA-256
values, and builds them with a C compiler and CMake. Cargo builds the Rust
TypeScript transpiler. The Cyna compiler builds the CLI and embedding archive.
A release package should include the CLI, the `build/modules` directory,
`include/addon.h`, `include/hao.h`, and the embedding archive with its link
metadata and dependency libraries.

The hosted workflow currently checks source, TypeScript declarations, and C
headers. Binary publishing waits for a distributable pinned Cyna toolchain.
The previous Zig release process remains available on the `legacy` branch.
