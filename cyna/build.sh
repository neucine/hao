#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig build cyna-deps -Doptimize=ReleaseFast
cyna build cyna
cyna build cyna/embed
mkdir -p cyna/build/modules
cp src/std/runtime/index.ts cyna/build/modules/runtime.ts
cp cyna/modules/fs.ts cyna/build/modules/fs.ts
cp cyna/modules/process.ts cyna/build/modules/process.ts
cp src/std/plot/index.ts cyna/build/modules/plot.ts
cp cyna/modules/util.ts cyna/build/modules/util.ts
cp cyna/modules/http.ts cyna/build/modules/http.ts
cp cyna/modules/http_server.ts cyna/build/modules/http_server.ts
cp src/std/telemetry/index.ts cyna/build/modules/telemetry.ts
cp cyna/modules/telemetry_native.ts cyna/build/modules/telemetry_native.ts
cp cyna/modules/telemetry_console.ts cyna/build/modules/telemetry_console.ts
python3 - src/telemetry/dashboard.html cyna/build/modules/telemetry_dashboard.ts <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text('export const dashboard = ' + json.dumps(pathlib.Path(sys.argv[1]).read_text()) + ';\n')
PY
cp src/std/ffi/index.ts cyna/build/modules/ffi.ts
cp src/std/ffi/c.ts cyna/build/modules/ffi_c.ts
cp cyna/modules/ffi_native.ts cyna/build/modules/ffi_native.ts
cp cyna/modules/ffi_c_native.ts cyna/build/modules/ffi_c_native.ts
cp cyna/modules/test_native.ts cyna/build/modules/test_native.ts
cp src/std/test/index.ts cyna/build/modules/test.ts
