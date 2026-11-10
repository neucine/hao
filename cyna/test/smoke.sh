#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime="$repo_root/cyna/build/hao-cyna"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT HUP INT TERM

printf 'export const answer: number = 42;\n' > "$fixture_dir/value.ts"
printf 'import { answer } from "./value.ts"; console.log("answer", answer); Promise.resolve().then(() => console.log("drained"));\n' > "$fixture_dir/main.ts"
actual=$("$runtime" "$fixture_dir/main.ts")
expected=$(printf 'answer 42\ndrained')
test "$actual" = "$expected"
relative_actual=$(cd "$fixture_dir" && "$runtime" main.ts)
test "$relative_actual" = "$expected"

printf 'import runtime, { name, namespace } from "std:runtime"; console.log(name, namespace, runtime.name);\n' > "$fixture_dir/standard.ts"
standard_actual=$("$runtime" "$fixture_dir/standard.ts")
test "$standard_actual" = 'hao std: hao'

printf "import fs from 'std:fs'; const path = '%s/data.txt'; console.log(fs.existsSync(path)); fs.writeFileSync(path, 'hello'); console.log(fs.existsSync(path), fs.readFileSync(path), fs.statSync(path).size);\n" "$fixture_dir" > "$fixture_dir/filesystem.ts"
filesystem_actual=$("$runtime" "$fixture_dir/filesystem.ts")
filesystem_expected=$(printf 'false\ntrue hello 5')
test "$filesystem_actual" = "$filesystem_expected"

mkdir -p "$fixture_dir/app/node_modules/demo" "$fixture_dir/app/node_modules/@scope/tool" "$fixture_dir/vendor/external"
printf '{"type":"module","exports":{".":{"import":"./index.ts"},"./extra":"./extra.mjs"}}\n' > "$fixture_dir/app/node_modules/demo/package.json"
printf 'export const value: number = 42;\n' > "$fixture_dir/app/node_modules/demo/index.ts"
printf 'export const extra = 3;\n' > "$fixture_dir/app/node_modules/demo/extra.mjs"
printf '{"type":"module","main":"./index.js"}\n' > "$fixture_dir/app/node_modules/@scope/tool/package.json"
printf 'export const scoped = 7;\n' > "$fixture_dir/app/node_modules/@scope/tool/index.js"
printf 'import { value } from "demo"; import { extra } from "demo/extra"; import { scoped } from "@scope/tool"; console.log(value, extra, scoped);\n' > "$fixture_dir/app/packages.ts"
test "$("$runtime" "$fixture_dir/app/packages.ts")" = '42 3 7'
printf '{"exports":"./index.mjs"}\n' > "$fixture_dir/vendor/external/package.json"
printf 'export const value = 11;\n' > "$fixture_dir/vendor/external/index.mjs"
printf 'import { value } from "external"; console.log("external", value);\n' > "$fixture_dir/app/external.ts"
test "$(RUNTIME_PACKAGE_PATH="$fixture_dir/vendor" "$runtime" "$fixture_dir/app/external.ts")" = 'external 11'
printf 'import "demo/private";\n' > "$fixture_dir/app/unexported.ts"
if "$runtime" "$fixture_dir/app/unexported.ts" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected an unexported package subpath to fail' >&2
    exit 1
fi
grep -q 'Cannot resolve package: demo/private' "$fixture_dir/stderr"

printf 'console.log("before"); const cancelled = setTimeout(() => console.log("cancelled"), 1); clearTimeout(cancelled); setTimeout(() => { console.log("after"); Promise.resolve().then(() => console.log("microtask")); }, 1);\n' > "$fixture_dir/timer.ts"
timer_actual=$("$runtime" "$fixture_dir/timer.ts")
timer_expected=$(printf 'before\nafter\nmicrotask')
test "$timer_actual" = "$timer_expected"

printf 'setTimeout(() => { throw new Error("timer failed"); }, 1);\n' > "$fixture_dir/timer-failure.ts"
if "$runtime" "$fixture_dir/timer-failure.ts" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected timer callback to exit with an error' >&2
    exit 1
fi
grep -q 'Error: timer failed' "$fixture_dir/stderr"

printf 'throw new Error("expected failure");\n' > "$fixture_dir/failure.js"
if "$runtime" "$fixture_dir/failure.js" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected failure script to exit with an error' >&2
    exit 1
fi
grep -q 'Error: expected failure' "$fixture_dir/stderr"
