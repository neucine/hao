#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$repo_root"
required_cyna='cyna 0.5.1-beta.1'
installed_cyna=$(cyna version 2>&1)
if [ "$installed_cyna" != "$required_cyna" ]; then
    echo "Hao Cyna port requires $required_cyna; found $installed_cyna" >&2
    exit 1
fi
sh build_deps.sh
cyna build .
cyna build cyna.lib.toml --output build/libhao-cyna-embed.a
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
