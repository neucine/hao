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
