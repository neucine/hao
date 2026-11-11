#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$repo_root"
cyna_revision=f069052
cyna_source=${HAO_CYNA_SOURCE:-"$repo_root/.deps/cyna-source"}
if ! git -C "$cyna_source" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet --branch codex/hao-bounded-read-current --single-branch \
        https://github.com/neucine/cyna.git "$cyna_source"
    git -C "$cyna_source" checkout --quiet --detach "$cyna_revision"
fi
actual_revision=$(git -C "$cyna_source" rev-parse --short=7 HEAD)
if [ "$actual_revision" != "$cyna_revision" ]; then
    echo "Hao requires Cyna source $cyna_revision; found $actual_revision" >&2
    exit 1
fi
zig_libs_revision=a91b58271be94a4e402a856403fe0fa83add1709
zig_libs_source="$(dirname "$cyna_source")/zig-libs"
if ! git -C "$zig_libs_source" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet https://github.com/neucine/zig-libs.git "$zig_libs_source"
    git -C "$zig_libs_source" checkout --quiet --detach "$zig_libs_revision"
fi
actual_zig_libs=$(git -C "$zig_libs_source" rev-parse HEAD)
if [ "$actual_zig_libs" != "$zig_libs_revision" ]; then
    echo "Hao requires zig-libs $zig_libs_revision; found $actual_zig_libs" >&2
    exit 1
fi
if [ "$(zig version)" != '0.17.0' ]; then
    echo 'Hao requires Zig 0.17.0 to build its pinned Cyna compiler' >&2
    exit 1
fi
(cd "$cyna_source" && zig build)
cyna_bin="$cyna_source/zig-out/bin/cyna"
sh build_deps.sh
"$cyna_bin" build .
"$cyna_bin" build cyna.lib.toml --output build/libhao-cyna-embed.a
mkdir -p build/modules
cp src/std/runtime/index.ts build/modules/runtime.ts
cp src/std/fs/index.ts build/modules/fs.ts
cp src/std/fs/native.ts build/modules/fs_native.ts
cp src/std/process/index.ts build/modules/process.ts
cp src/std/process/native.ts build/modules/process_native.ts
cp src/std/plot/index.ts build/modules/plot.ts
cp src/std/util/index.ts build/modules/util.ts
cp src/std/util/native.ts build/modules/util_native.ts
cp src/std/http/index.ts build/modules/http.ts
cp src/std/http/native.ts build/modules/http_native.ts
cp src/std/http/server.ts build/modules/http_server.ts
cp src/std/telemetry/index.ts build/modules/telemetry.ts
cp src/std/telemetry/native.ts build/modules/telemetry_native.ts
cp src/std/telemetry/console.ts build/modules/telemetry_console.ts
python3 - src/telemetry/dashboard.html build/modules/telemetry_dashboard.ts <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text('export const dashboard = ' + json.dumps(pathlib.Path(sys.argv[1]).read_text()) + ';\n')
PY
cp src/std/ffi/index.ts build/modules/ffi.ts
cp src/std/ffi/c.ts build/modules/ffi_c.ts
cp src/std/ffi/native.ts build/modules/ffi_native.ts
cp src/std/ffi/c_abi/ast.ts build/modules/ffi_c_abi_ast.ts
cp src/std/ffi/c_abi/metadata.ts build/modules/ffi_c_abi_metadata.ts
cp src/std/ffi/c_abi/errors.ts build/modules/ffi_c_abi_errors.ts
cp src/std/ffi/c_abi/lower.ts build/modules/ffi_c_abi_lower.ts
cp src/std/ffi/c_abi/parser.ts build/modules/ffi_c_abi_parser.ts
cp src/std/ffi/c_abi/struct_runtime.ts build/modules/ffi_c_abi_struct_runtime.ts
cp src/std/ffi/c_native.ts build/modules/ffi_c_native.ts
cp src/std/test/native.ts build/modules/test_native.ts
cp src/std/test/index.ts build/modules/test.ts
