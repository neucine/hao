#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig build -Doptimize=ReleaseFast
cyna build cyna
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
cp cyna/modules/test_native.ts cyna/build/modules/test_native.ts
cp src/std/test/index.ts cyna/build/modules/test.ts
