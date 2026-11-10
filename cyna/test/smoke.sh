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

printf "import { figure, plot, render, savefig } from 'std:plot'; import fs from 'std:fs'; figure({ title: 'Demo' }); plot([1, 2, 3]); console.log(render().includes('<svg')); savefig('%s/chart.svg'); console.log(fs.readFileSync('%s/chart.svg').includes('Demo'));\n" "$fixture_dir" "$fixture_dir" > "$fixture_dir/plot.ts"
plot_actual=$("$runtime" "$fixture_dir/plot.ts")
plot_expected=$(printf 'true\ntrue')
test "$plot_actual" = "$plot_expected"

cat > "$fixture_dir/util.ts" <<'EOF'
import util, { inspect, setInspectOptions, getInspectOptions } from 'std:util';
console.log(inspect({ xs: [1, 2, 3], ok: true }));
setInspectOptions({ maxArrayLength: 2 });
console.log(inspect([1, 2, 3]), getInspectOptions().maxArrayLength);
console.log(util.inspect({ repr() { return { mime: 'image/svg+xml', data: '<svg />' }; }, toString() { return 'fallback'; } }));
const cycle: any = {}; cycle.self = cycle;
console.log(inspect(cycle));
EOF
util_actual=$("$runtime" "$fixture_dir/util.ts")
util_expected=$(printf '{ xs: [ 1, 2, 3 ], ok: true }\n[ 1, 2, ... 1 more items ] 2\n<svg />\n{ self: [Circular] }')
test "$util_actual" = "$util_expected"

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

cat > "$fixture_dir/process.ts" <<'EOF'
import { getEnv, run } from 'std:process';
console.log('env', getEnv('HAO_CYNA_TEST'));
const output = await run({ cmd: 'sh', args: ['-c', 'printf hello; printf warn >&2'] });
console.log('run', output.stdout, output.stderr, output.exitCode);
const value = await run("printf '{\"value\":42}'").json();
console.log('json', value.value);
const unchecked = await run({ cmd: 'sh', args: ['-c', 'exit 7'], check: false });
console.log('unchecked', unchecked.exitCode);
try { await run({ cmd: 'sh', args: ['-c', 'exit 9'] }); } catch (error) { console.log('checked', error.exitCode); }
try { await run({ cmd: 'sh', args: ['-c', 'printf 12345'], maxOutputBytes: 3 }); } catch (error) { console.log('limited', error.message); }
EOF
process_actual=$(HAO_CYNA_TEST=works "$runtime" "$fixture_dir/process.ts")
process_expected=$(printf 'env works\nrun hello warn 0\njson 42\nunchecked 7\nchecked 9\nlimited process output exceeds maxOutputBytes')
test "$process_actual" = "$process_expected"

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
