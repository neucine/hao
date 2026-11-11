# Embedding Hao

The Cyna library manifest is `cyna.lib.toml`. The build produces
`build/libhao-cyna-embed.a` and exposes its C
interface in `include/hao.h`. Create a runtime with `hao_embed_new`, register
source modules with `hao_embed_register_module`, evaluate a module with
`hao_embed_eval`, drain pending Promise and native work with
`hao_embed_run_until_idle`, and release the handle with `hao_embed_free`.
For a host supplied QuickJS module, call `hao_embed_register_native_module`
with a specifier and a loader callback. The loader receives the runtime's
QuickJS context and the requested module name and returns a `JSModuleDef *`.
It is called when the module is imported. Its function pointer must remain
valid until the runtime is freed. Source and native modules share one name
space, so duplicate specifiers are rejected.
`hao_embed_register_package_callbacks` registers lifecycle callbacks by
package name. Install callbacks run in registration order before every module
evaluation. If one returns a nonzero value, evaluation stops and
`hao_embed_last_error` reports the installation failure. Deinit callbacks run
once in reverse registration order when the runtime is freed. The callback
function pointers and userdata must remain valid for the runtime lifetime.
`hao_embed_register_package` registers sources, native modules, and callbacks
in one call. It checks each module specifier against the package name, rejects
duplicates, and leaves the registry unchanged if any member is invalid.
Use this form when a host owns a package with several modules.

`hao_embed_install_std` installs the standard modules from the directory
produced by `sh build.sh` (`build/modules`). Hosts that do not use
`std:` modules can omit it. Compare `hao_embed_abi_version()` with
`HAO_EMBED_ABI_VERSION` before using a separately built archive.

Each successful `hao_embed_new` call owns an independent module registry and
must be paired with one `hao_embed_free` call. Source and module names are
copied before registration returns. A null byte pointer is accepted only with
a zero length. Module specifiers must be nonempty and contain no NUL byte.
Calls return zero on success. After a failed operation,
`hao_embed_last_error` returns the full error length and copies a terminated
message into a caller-owned buffer. The next successful operation clears it.
Runtime errors are also written to stderr.

The archive currently targets macOS arm64. Link it with the Cyna runtime and
standard library archives, QuickJS, libuv, the Hao transpiler, libcurl, libffi,
libzmq, and OpenSSL. The checked C consumer and its linker invocation are in
`test/port/embed_consumer.c` and `test/port/smoke.sh`.
