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
configured_actual=$(RUNTIME_QJS_STACK_SIZE=16777216 RUNTIME_QJS_GC_THRESHOLD=1048576 RUNTIME_LIBUV_THREADPOOL_SIZE=4 "$runtime" "$fixture_dir/main.ts")
test "$configured_actual" = "$expected"
if RUNTIME_QJS_STACK_SIZE=invalid "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/config.stdout" 2> "$fixture_dir/config.stderr"; then
    exit 1
fi

mkdir -p "$fixture_dir/node_modules/foo"
clang -dynamiclib -I "$repo_root/include" "$repo_root/examples/native-addon/native.c" -o "$fixture_dir/node_modules/foo/native.dylib"
cat > "$fixture_dir/node_modules/foo/package.json" <<'EOF'
{"type":"module","exports":{"./native":"./native.dylib","./extra":"./native.dylib"}}
EOF
cat > "$fixture_dir/addon.ts" <<'EOF'
import native from 'foo:native';
import extra from 'foo:extra';
console.log(native.foo(), native.add(2, 3), native.pair('a', 'b').join(','), extra.label());
EOF
addon_actual=$("$runtime" "$fixture_dir/addon.ts")
test "$addon_actual" = 'hao 5 a,b extra'

mkdir -p "$fixture_dir/node_modules/metric"
clang -dynamiclib -I "$repo_root/include" "$repo_root/cyna/test/metric_addon.c" -o "$fixture_dir/node_modules/metric/native.dylib"
cat > "$fixture_dir/node_modules/metric/package.json" <<'EOF'
{"type":"module","exports":{"./native":"./native.dylib"}}
EOF
cat > "$fixture_dir/addon_metric.ts" <<'EOF'
import metric from 'metric:native';
import { metrics } from 'std:telemetry';
console.log(metric.increment(), metric.increment());
const calls = metrics().find(item => item.scope === 'addon' && item.name === 'calls');
console.log(calls?.value, calls?.kind, calls?.unit);
EOF
metric_actual=$("$runtime" "$fixture_dir/addon_metric.ts")
test "$metric_actual" = "$(printf '1 2\n2 counter count')"

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

server_info=$(python3 "$repo_root/test/e2e/http/server.py")
set -- $server_info
server_port=$1
server_pid=$2
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$fixture_dir"' EXIT HUP INT TERM
cat > "$fixture_dir/http.ts" <<EOF
import { get, post } from 'std:http';
const response = await get('http://127.0.0.1:$server_port/json', { query: { q: 'hello world' } });
console.log(response.status, response.json().path, response.headers['Content-Type']);
const sent = await post('http://127.0.0.1:$server_port/echo', { json: { answer: 42 } });
console.log(sent.json().body);
const binary = await get('http://127.0.0.1:$server_port/bytes');
console.log(Array.from(binary.bytes()).join(','));
const manual = await get('http://127.0.0.1:$server_port/download-redirect', { redirect: 'manual' });
console.log(manual.status, manual.headers['Location']);
try { await get('http://127.0.0.1:$server_port/large', { maxBytes: 10 }); } catch (error) { console.log(error.message); }
EOF
http_actual=$("$runtime" "$fixture_dir/http.ts")
http_expected=$(printf '200 /json?q=hello%%20world application/json\n{"answer":42}\n0,1,2,255\n302 /large\nhttp response exceeds maxBytes')
test "$http_actual" = "$http_expected"
cat > "$fixture_dir/download.ts" <<EOF
import { download } from 'std:http';
import fs from 'std:fs';
const path = '$fixture_dir/download.bin';
fs.writeFileSync(path, 'original');
const result = await download('http://127.0.0.1:$server_port/download-redirect', path, { maxBytes: 4194304 });
console.log(result.status, result.bytesWritten, result.sha256, fs.statSync(path).size);
try { await download('http://127.0.0.1:$server_port/large', path, { maxBytes: 10 }); } catch (_) { console.log('limited', fs.statSync(path).size); }
try { await download('http://127.0.0.1:$server_port/missing', path); } catch (_) { console.log('missing', fs.statSync(path).size); }
try { await download('http://127.0.0.1:$server_port/truncated', path); } catch (_) { console.log('truncated', fs.statSync(path).size); }
try { await download('http://127.0.0.1:$server_port/empty', '$fixture_dir/absent/file'); } catch (_) { console.log('parent', fs.statSync(path).size); }
const compressed = await download('http://127.0.0.1:$server_port/compressed', path, { maxBytes: 200000 });
console.log('compressed', compressed.bytesWritten, fs.statSync(path).size);
EOF
download_actual=$("$runtime" "$fixture_dir/download.ts")
download_expected=$(printf '200 4194304 2b07811057df887086f06a67edc6ebf911de8b6741156e7a2eb1416a4b8b1b2e 4194304\nlimited 4194304\nmissing 4194304\ntruncated 4194304\nparent 4194304\ncompressed 200000 200000')
test "$download_actual" = "$download_expected"
test "$(find "$fixture_dir" -name 'download.bin.hao-*' | wc -l | tr -d ' ')" = 0
python3 "$repo_root/cyna/test/http_server.py" "$runtime" > "$fixture_dir/server-behavior"
grep -q 'HTTP server behavior checks passed' "$fixture_dir/server-behavior"
(cd "$repo_root" && python3 test/e2e/http/server-wire.py "$runtime") > "$fixture_dir/server-wire"
grep -q 'wire framing and deadline checks passed' "$fixture_dir/server-wire"
cat > "$fixture_dir/http-in-process.ts" <<'EOF'
import { serve, get, post } from 'std:http';
const server = serve({ port: 0, async handler(request) {
  await new Promise(resolve => setTimeout(resolve, 2));
  return { json: { method: request.method, path: request.url } };
} });
const base = `http://127.0.0.1:${server.port}`;
let timerFired = false;
setTimeout(() => { timerFired = true; }, 1);
const [first, second] = await Promise.all([get(base + '/one'), post(base + '/two')]);
console.log(first.json().path, second.json().method, timerFired);
server.close();
EOF
test "$("$runtime" "$fixture_dir/http-in-process.ts")" = '/one POST true'

test_summary=$("$runtime" test "$repo_root/test/e2e/test" | tail -1)
test "$test_summary" = '30 passed, 0 failed, 7 skipped'
cat > "$fixture_dir/expected-failure.test.ts" <<'EOF'
import { test, expect } from 'std:test';
test('failure changes exit status', () => expect(1).toBe(2));
EOF
if "$runtime" test "$fixture_dir/expected-failure.test.ts" > "$fixture_dir/test-output" 2> "$fixture_dir/stderr"; then
    echo 'expected a failing test to exit with an error' >&2
    exit 1
fi
grep -q '0 passed, 1 failed, 0 skipped' "$fixture_dir/test-output"
cat > "$fixture_dir/capture-child.ts" <<'EOF'
console.log('child output');
console.error('child warning');
EOF
cat > "$fixture_dir/capture.test.ts" <<'EOF'
import { test, expect, captureOutput } from 'std:test';
test('captures async output and restores the console', async () => {
  const result = await captureOutput(async () => {
    console.log('first');
    await new Promise(resolve => setTimeout(resolve, 1));
    console.error('second');
  }, { target: 'both' });
  expect(result.stdout).toBe('first\n');
  expect(result.stderr).toBe('second\n');
  expect(result.combined).toBe('first\nsecond\n');
});
test('captures a child file', async () => {
  const result = await captureOutput('capture-child.ts');
  expect(result.exitCode).toBe(0);
  expect(result.stdout).toBe('child output\n');
  expect(result.stderr).toBe('child warning\n');
});
EOF
capture_summary=$("$runtime" test "$fixture_dir/capture.test.ts" | tail -1)
test "$capture_summary" = '2 passed, 0 failed, 0 skipped'
telemetry_summary=$("$runtime" test "$repo_root/test/e2e/telemetry/metrics.test.ts" | tail -1)
test "$telemetry_summary" = '4 passed, 0 failed, 0 skipped'
ffi_summary=$("$runtime" test "$repo_root/test/e2e/ffi" | tail -1)
test "$ffi_summary" = '4 passed, 0 failed, 0 skipped'
error_summary=$("$runtime" test "$repo_root/test/e2e/runtime/errors.test.ts" | tail -1)
test "$error_summary" = '2 passed, 0 failed, 0 skipped'
cat > "$fixture_dir/ffi-mixed.ts" <<'EOF'
import { dlopen } from 'std:ffi';
const math = dlopen('m', { ldexp: { args: ['f64', 'i32'], returns: 'f64' } });
console.log(math.ldexp(1.5, 3));
math.close();
EOF
test "$("$runtime" "$fixture_dir/ffi-mixed.ts")" = 12

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
