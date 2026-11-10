# Embedding Hao

The Cyna build produces `cyna/embed/build/libhao-cyna-embed.a` and exposes its C
interface in `include/hao.h`. Create a runtime with `hao_embed_new`, register
source modules with `hao_embed_register_module`, evaluate a module with
`hao_embed_eval`, drain pending Promise and native work with
`hao_embed_run_until_idle`, and release the handle with `hao_embed_free`.

`hao_embed_install_std` installs the standard modules from the directory
produced by `sh cyna/build.sh` (`cyna/build/modules`). Hosts that do not use
`std:` modules can omit it. Compare `hao_embed_abi_version()` with
`HAO_EMBED_ABI_VERSION` before using a separately built archive.

Each successful `hao_embed_new` call owns an independent module registry and
must be paired with one `hao_embed_free` call. Source and module names are
copied before registration returns. A null byte pointer is accepted only with
a zero length. Calls return zero on success. After a failed operation,
`hao_embed_last_error` returns the full error length and copies a terminated
message into a caller-owned buffer. The next successful operation clears it.
Runtime errors are also written to stderr.

The archive currently targets macOS arm64. Link it with the Cyna runtime and
standard library archives, QuickJS, libuv, the Hao transpiler, libcurl, libffi,
libzmq, and OpenSSL. The checked C consumer and its linker invocation are in
`cyna/test/embed_consumer.c` and `cyna/test/smoke.sh`.
