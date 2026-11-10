#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
required_cyna='cyna 0.5.1-beta.1'
installed_cyna=$(cyna version 2>&1)
if [ "$installed_cyna" != "$required_cyna" ]; then
    echo "Hao Cyna port requires $required_cyna; found $installed_cyna" >&2
    exit 1
fi
sh cyna/build_deps.sh
cyna build cyna
cyna build cyna/embed
mkdir -p cyna/build/modules
cp cyna/src/std/runtime/index.ts cyna/build/modules/runtime.ts
cp cyna/src/std/fs/index.ts cyna/build/modules/fs.ts
cp cyna/src/std/fs/native.ts cyna/build/modules/fs_native.ts
cp cyna/src/std/process/index.ts cyna/build/modules/process.ts
cp cyna/src/std/process/native.ts cyna/build/modules/process_native.ts
cp cyna/src/std/plot/index.ts cyna/build/modules/plot.ts
cp cyna/src/std/util/index.ts cyna/build/modules/util.ts
cp cyna/src/std/util/native.ts cyna/build/modules/util_native.ts
cp cyna/src/std/http/index.ts cyna/build/modules/http.ts
cp cyna/src/std/http/server.ts cyna/build/modules/http_server.ts
cp cyna/src/std/telemetry/index.ts cyna/build/modules/telemetry.ts
cp cyna/src/std/telemetry/native.ts cyna/build/modules/telemetry_native.ts
cp cyna/src/std/telemetry/console.ts cyna/build/modules/telemetry_console.ts
python3 - cyna/src/telemetry/dashboard.html cyna/build/modules/telemetry_dashboard.ts <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text('export const dashboard = ' + json.dumps(pathlib.Path(sys.argv[1]).read_text()) + ';\n')
PY
cp cyna/src/std/ffi/index.ts cyna/build/modules/ffi.ts
cp cyna/src/std/ffi/c.ts cyna/build/modules/ffi_c.ts
cp cyna/src/std/ffi/native.ts cyna/build/modules/ffi_native.ts
cp cyna/src/std/ffi/c_native.ts cyna/build/modules/ffi_c_native.ts
cp cyna/src/std/test/native.ts cyna/build/modules/test_native.ts
cp cyna/src/std/test/index.ts cyna/build/modules/test.ts
