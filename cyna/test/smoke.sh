#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime="$repo_root/cyna/build/hao-cyna"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT HUP INT TERM
test "$("$runtime" --version)" = 'hao 0.1.2'
test "$("$runtime" -v)" = 'hao 0.1.2'
python3 - "$runtime" <<'PY'
import subprocess, sys
for args in ([], ['jupyter', 'unknown']):
    result = subprocess.run([sys.argv[1], *args], capture_output=True, text=True)
    assert result.returncode == 2 and result.stdout == ''
    assert result.stderr.startswith('Usage:\n  hao <file.ts|file.js>\n')
    assert 'hao jupyter install\n' in result.stderr
PY

printf 'export const answer: number = 42;\n' > "$fixture_dir/value.ts"
printf 'import { answer } from "./value.ts"; console.log("answer", answer); Promise.resolve().then(() => console.log("drained"));\n' > "$fixture_dir/main.ts"
actual=$("$runtime" "$fixture_dir/main.ts")
expected=$(printf 'answer 42\ndrained')
test "$actual" = "$expected"
relative_actual=$(cd "$fixture_dir" && "$runtime" main.ts)
test "$relative_actual" = "$expected"
cyna_dir=$(CDPATH= cd -- "$(dirname -- "$(command -v cyna)")/.." && pwd -P)
clang -I "$repo_root/include" "$repo_root/cyna/test/embed_consumer.c" \
    "$repo_root/cyna/embed/build/libhao-cyna-embed.a" \
    -L "$cyna_dir/targets/aarch64-apple-darwin/lib" -lcyna_std -lcyna \
    -L "$repo_root/cyna/.deps/install/lib" -lquickjs -luv \
    -L "$repo_root/libs/transpiler/target/release" -lhao_transpiler \
    -L /opt/homebrew/lib -lcurl -lffi -lzmq -lcrypto -o "$fixture_dir/embed-consumer" 2> "$fixture_dir/embed-link.log"
test "$("$fixture_dir/embed-consumer" "$repo_root/cyna/build/modules" 2> "$fixture_dir/embed-error.log")" = '42'
clang -I /opt/homebrew/include "$repo_root/cyna/test/jupyter_wire_test.c" \
    "$repo_root/cyna/src/jupyter/zmq.c" -L /opt/homebrew/lib -lzmq -lcrypto \
    -o "$fixture_dir/jupyter-wire-test"
test "$("$fixture_dir/jupyter-wire-test")" = 'wire ok'
clang -I /opt/homebrew/include "$repo_root/cyna/test/jupyter_kernel_test.c" \
    -L /opt/homebrew/lib -lzmq -lcrypto -o "$fixture_dir/jupyter-kernel-test"
test "$("$fixture_dir/jupyter-kernel-test" "$runtime")" = 'kernel ok'
HAO_JUPYTER_KERNEL_DIR="$fixture_dir/kernels/hao" "$runtime" jupyter install > "$fixture_dir/kernelspec-output"
python3 - "$fixture_dir/kernels/hao/kernel.json" "$runtime" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    spec = json.load(source)
assert spec['argv'] == [sys.argv[2], 'jupyter', '--connection-file', '{connection_file}']
assert spec['display_name'] == 'Hao (TypeScript)'
PY
cat > "$fixture_dir/jupyter-connection.json" <<'EOF'
{"shell_port":57503,"control_port":57504,"iopub_port":57505,"stdin_port":57506,"hb_port":57507}
EOF
cat > "$fixture_dir/jupyter-explicit.json" <<'EOF'
{"transport":"ipc","ip":"0.0.0.0","shell_port":1,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5,"key":"secret","signature_scheme":"hmac-sha256"}
EOF
cyna build "$repo_root/cyna/src/jupyter/connection_check.cy" --output "$fixture_dir/jupyter-connection-check" > "$fixture_dir/jupyter-build.log" 2>&1
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-connection.json")" = "$(printf 'tcp://127.0.0.1:57503\n\nhmac-sha256')"
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-explicit.json")" = "$(printf 'ipc://0.0.0.0:1\nsecret\nhmac-sha256')"
if "$fixture_dir/jupyter-connection-check" "$fixture_dir/main.ts" > "$fixture_dir/jupyter-invalid.log" 2>&1; then
    exit 1
fi
cat > "$fixture_dir/jupyter-invalid-port.json" <<'EOF'
{"shell_port":65536,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5}
EOF
if "$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-invalid-port.json" > "$fixture_dir/jupyter-invalid.log" 2>&1; then
    exit 1
fi
configured_actual=$(RUNTIME_QJS_STACK_SIZE=16777216 RUNTIME_QJS_GC_THRESHOLD=1048576 RUNTIME_LIBUV_THREADPOOL_SIZE=4 "$runtime" "$fixture_dir/main.ts")
test "$configured_actual" = "$expected"
if RUNTIME_QJS_STACK_SIZE=invalid "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/config.stdout" 2> "$fixture_dir/config.stderr"; then
    exit 1
fi
cat > "$fixture_dir/settings.env" <<'EOF'
# startup settings and quoted values
export HAO_DOTENV_TEST="loaded # intact"
RUNTIME_QJS_STACK_SIZE=16777216 # comment
EOF
cat > "$fixture_dir/dotenv.ts" <<'EOF'
import { getEnv } from 'std:process';
console.log(getEnv('HAO_DOTENV_TEST'));
EOF
dotenv_actual=$(DOTENV="$fixture_dir/settings.env" "$runtime" "$fixture_dir/dotenv.ts")
test "$dotenv_actual" = 'loaded # intact'
dotenv_override=$(HAO_DOTENV_TEST=existing DOTENV="$fixture_dir/settings.env" "$runtime" "$fixture_dir/dotenv.ts")
test "$dotenv_override" = 'existing'
cp "$fixture_dir/settings.env" "$fixture_dir/.env"
dotenv_default=$(cd "$fixture_dir" && env -u DOTENV "$runtime" dotenv.ts)
test "$dotenv_default" = 'loaded # intact'
if DOTENV="$fixture_dir/missing.env" "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/dotenv.stdout" 2> "$fixture_dir/dotenv.stderr"; then
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
test "$test_summary" = '31 passed, 0 failed, 7 skipped'
cat > "$fixture_dir/explicit.ts" <<'EOF'
import { test, expect } from 'std:test';
test('explicit file', () => expect(2 + 2).toBe(4));
EOF
test "$("$runtime" test "$fixture_dir/explicit.ts" | tail -1)" = '1 passed, 0 failed, 0 skipped'
cat > "$fixture_dir/z-order.test.ts" <<'EOF'
import { test } from 'std:test';
test('z order', () => {});
EOF
cat > "$fixture_dir/a-order.test.ts" <<'EOF'
import { test } from 'std:test';
test('a order', () => {});
EOF
order_actual=$("$runtime" test "$fixture_dir/z-order.test.ts" "$fixture_dir/a-order.test.ts" | sed -n '/^PASS /p')
order_expected=$(printf 'PASS a order\nPASS z order')
test "$order_actual" = "$order_expected"
python3 - "$runtime" "$repo_root/test/e2e/runtime/hello.test.ts" <<'PY'
import os, subprocess, sys
result = subprocess.run([sys.argv[1], 'test', sys.argv[2]], env=dict(os.environ, RUNTIME_TEST_REPORTER='ansi'),
                        capture_output=True, text=True, check=True)
assert '\x1b[32mPASS\x1b[0m' in result.stdout
assert 'Time: ' in result.stdout
assert result.stdout.rstrip().endswith('1 passed, 0 failed, 0 skipped')
PY
cat > "$fixture_dir/expected-failure.test.ts" <<'EOF'
import { test, expect } from 'std:test';
test('failure changes exit status', () => expect(1).toBe(2));
EOF
if "$runtime" test "$fixture_dir/expected-failure.test.ts" > "$fixture_dir/test-output" 2> "$fixture_dir/stderr"; then
    echo 'expected a failing test to exit with an error' >&2
    exit 1
fi
grep -q '0 passed, 1 failed, 0 skipped' "$fixture_dir/test-output"
cat > "$fixture_dir/hook-failure.test.ts" <<'EOF'
import { describe, test, beforeAll, beforeEach, afterEach, afterAll } from 'std:test';
describe('blocked', () => {
  beforeAll(() => { throw Error('setup failed'); });
  afterAll(() => console.log('blocked cleanup'));
  test('first', () => {});
  test('second', () => {});
});
describe('partial setup', () => {
  beforeEach(() => console.log('outer setup'));
  afterEach(() => console.log('outer cleanup'));
  describe('inner', () => {
    beforeEach(() => { throw Error('inner setup failed'); });
    afterEach(() => console.log('inner cleanup'));
    test('body', () => console.log('body should not run'));
  });
});
EOF
if "$runtime" test "$fixture_dir/hook-failure.test.ts" > "$fixture_dir/hook-output" 2> "$fixture_dir/hook-stderr"; then
    exit 1
fi
grep -q '0 passed, 2 failed, 1 skipped' "$fixture_dir/hook-output"
grep -q 'outer cleanup' "$fixture_dir/hook-output"
if grep -q 'inner cleanup\|body should not run' "$fixture_dir/hook-output"; then
    exit 1
fi
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
cat > "$fixture_dir/telemetry-console.ts" <<'EOF'
import { counter, trace } from 'std:telemetry';
counter({ scope: 'fixture', name: 'requests' }).add(3);
trace('fixture-trace', () => {});
setTimeout(() => {}, 1500);
EOF
python3 - "$runtime" "$fixture_dir/telemetry-console.ts" <<'PY'
import json, os, re, subprocess, sys, urllib.request
env = dict(os.environ, RUNTIME_TELEMETRY_CONSOLE='1', RUNTIME_TELEMETRY_CONSOLE_PORT='0')
process = subprocess.Popen([sys.argv[1], sys.argv[2]], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    line = process.stderr.readline()
    match = re.search(r'http://127\.0\.0\.1:(\d+)/', line)
    assert match, line
    base = 'http://127.0.0.1:' + match.group(1)
    def get(path):
        with urllib.request.urlopen(base + path, timeout=2) as response:
            return response.read().decode()
    assert json.loads(get('/api/health')) == {'ok': True}
    assert any(metric['scope'] == 'fixture' and metric['value'] == 3 for metric in json.loads(get('/api/metrics')))
    traces = json.loads(get('/api/traces?since=0&limit=10'))
    assert [record['kind'] for record in traces['records'] if record['name'] == 'fixture-trace'] == ['span_start', 'span_end']
    later = json.loads(get('/api/traces?since=1&limit=1'))
    assert later['records'][0]['sequence'] == 2 and later['next_cursor'] == 2
    assert '<title>Hao Telemetry</title>' in get('/')
    assert process.wait(timeout=5) == 0
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
PY
cat > "$fixture_dir/telemetry-timer.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('root', () => setTimeout(() => {
  trace('child', () => {});
  const records = snapshotTraceRecordsNative().records;
  console.log(records[0].name, records[2].name, records[2].parent_span_id === records[0].span_id);
}, 1));
EOF
test "$("$runtime" "$fixture_dir/telemetry-timer.ts")" = 'root child true'
cat > "$fixture_dir/telemetry-ring.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
for (let i = 0; i < 260; i++) trace(`span-${i}`, () => {});
const page = snapshotTraceRecordsNative(1, 3);
console.log(page.missed, page.records.length, page.records[0].sequence, page.next_cursor);
EOF
test "$("$runtime" "$fixture_dir/telemetry-ring.ts")" = 'true 3 9 11'
ffi_summary=$("$runtime" test "$repo_root/test/e2e/ffi" | tail -1)
test "$ffi_summary" = '4 passed, 0 failed, 0 skipped'
error_summary=$("$runtime" test "$repo_root/test/e2e/runtime/errors.test.ts" | tail -1)
test "$error_summary" = '2 passed, 0 failed, 0 skipped'
cat > "$fixture_dir/broken.test.ts" <<'EOF'
import { describe, test, beforeEach } from 'std:test';
describe('partially loaded', () => {
  beforeEach(() => { throw Error('discard hook'); });
  test('must not run', () => { throw Error('discard case'); });
});
throw new Error('load failed');
EOF
cat > "$fixture_dir/after-broken.test.ts" <<'EOF'
import { test, expect, replaceProperty } from 'std:test';
const target = { value: 3 };
test('still runs', () => { replaceProperty(target, 'value', 9); expect(target.value).toBe(9); });
test('cleanup hook still runs', () => expect(target.value).toBe(3));
EOF
if load_result=$("$runtime" test "$fixture_dir/broken.test.ts" "$fixture_dir/after-broken.test.ts" 2>&1); then
    echo 'expected a failed test file to return failure' >&2
    exit 1
fi
case "$load_result" in
    *'Test Files: 1 loaded, 1 failed, 2 total'*'2 passed, 0 failed, 0 skipped'*) ;;
    *) echo "$load_result" >&2; exit 1 ;;
esac
cat > "$fixture_dir/ffi-mixed.ts" <<'EOF'
import { dlopen } from 'std:ffi';
const math = dlopen('m', { ldexp: { args: ['f64', 'i32'], returns: 'f64' } });
console.log(math.ldexp(1.5, 3));
math.close();
EOF
test "$("$runtime" "$fixture_dir/ffi-mixed.ts")" = 12
cat > "$fixture_dir/ffi-search.c" <<'EOF'
#include <stdint.h>
int hao_search_value(void) { return 29; }
int hao_make_handle(void **out) { *out = (void *)0x1234; return 0; }
int hao_fail_handle(void **out) { *out = (void *)0x1234; return 5; }
int hao_fail_with_code(int code) { return code ? -1 : 0; }
const char *hao_error_message(int code) { return code == 7 ? "status 7" : "other status"; }
typedef struct HaoBox { int value; } HaoBox;
HaoBox *hao_box_open(void) { static HaoBox box = { 37 }; return &box; }
int hao_box_value(HaoBox *box) { return box->value; }
void hao_box_close(HaoBox *box) { (void)box; }
typedef struct { double x; double y; } HaoPoint;
void hao_move_point(HaoPoint *point) { point->x += 2.5; point->y *= 3; }
typedef struct { uint8_t flag; double value; } HaoMixed;
void hao_update_mixed(HaoMixed *item) { item->flag = 7; item->value += 1.25; }
typedef struct { uint8_t tag; HaoPoint point; int16_t tail; } HaoNested;
void hao_update_nested(HaoNested *item) { item->point.x += 8; item->tail = 9; }
EOF
clang -dynamiclib "$fixture_dir/ffi-search.c" -o "$fixture_dir/libhao_search_fixture.dylib"
cat > "$fixture_dir/ffi-search.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = cdecl('hao_search_fixture', `/* status # ignored */ int hao_search_value(void); // first call
int hao_make_handle(void **out); int hao_fail_handle(void **out);
int hao_fail_with_code(int code); const char *hao_error_message(int code);`, {
  search: { strategy: 'relative-first', paths: [path] },
  functions: {
    hao_make_handle: { returns: { out: 'out' }, errors: { kind: 'status', ok: 0 } },
    hao_fail_handle: { returns: { out: 'out' }, errors: { kind: 'status', ok: 0 } },
    hao_fail_with_code: { errors: { kind: 'status', ok: 0, message: { from: 'hao_error_message', arg: 'code' } } },
  },
});
console.log(library.hao_search_value());
console.log(library.hao_make_handle());
try { library.hao_fail_handle(); } catch (error) { console.log(error.message); }
try { library.hao_fail_with_code(7); } catch (error) { console.log(error.message); }
library.close();
const fallback = cdecl('hao_search_fixture', 'int hao_search_value(void);', {
  search: { strategy: 'system-first', paths: [path] },
});
console.log(fallback.hao_search_value());
fallback.close();
const boxes = cdecl('hao_search_fixture',
  'typedef struct HaoBox HaoBox; HaoBox *hao_box_open(void); int hao_box_value(HaoBox *box); void hao_box_close(HaoBox *box);', {
    search: { strategy: 'relative-first', paths: [path] },
    handles: { HaoBox: { close: 'hao_box_close' } },
    functions: { hao_box_open: { returns: { kind: 'handle', type: 'HaoBox' } } },
  });
const box = boxes.hao_box_open();
console.log(boxes.hao_box_value(box));
box.close();
boxes.close();
const geometry = cdecl('hao_search_fixture',
  'typedef struct { double x; double y; } HaoPoint; void hao_move_point(HaoPoint *point);', {
    search: { strategy: 'relative-first', paths: [path] },
  });
const point = { x: 1.5, y: 4 };
geometry.hao_move_point(point);
console.log(point.x, point.y);
geometry.close();
const mixed = cdecl('hao_search_fixture',
  'typedef struct { uint8_t flag; double value; } HaoMixed; void hao_update_mixed(HaoMixed *item);', {
    search: { strategy: 'relative-first', paths: [path] },
  });
const item = { flag: 1, value: 2.5 };
mixed.hao_update_mixed(item);
console.log(item.flag, item.value);
mixed.close();
const nested = cdecl('hao_search_fixture',
  'typedef struct { double x; double y; } HaoPoint; typedef struct { uint8_t tag; HaoPoint point; int16_t tail; } HaoNested; void hao_update_nested(HaoNested *item);', {
    search: { strategy: 'relative-first', paths: [path] },
  });
const tree = { tag: 2, point: { x: 3, y: 4 }, tail: 5 };
nested.hao_update_nested(tree);
console.log(tree.tag, tree.point.x, tree.point.y, tree.tail);
nested.close();
try { cdecl('hao_search_fixture', '/* never closed'); }
catch (error) { console.log(error.message); }
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-search.ts")" = "$(printf '29\n4660\nhao_fail_handle failed\nstatus 7\n29\n37\n4 12\n7 3.75\n2 11 4 9\nunterminated C block comment')"
mv "$fixture_dir/libhao_search_fixture.dylib" "$fixture_dir/libhao_search_fixture.so"
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-search.ts")" = "$(printf '29\n4660\nhao_fail_handle failed\nstatus 7\n29\n37\n4 12\n7 3.75\n2 11 4 9\nunterminated C block comment')"

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
const signaled = await run({ cmd: 'sh', args: ['-c', 'kill -TERM $$'], check: false });
console.log('signaled', signaled.exitCode, signaled.signal);
const cwd = await run({ cmd: 'pwd', cwd: '/private/tmp' });
console.log('cwd', cwd.stdout.trim());
const largeLimit = await run({ cmd: 'sh', args: ['-c', 'printf ok'], maxOutputBytes: 17 * 1024 * 1024 });
console.log('largeLimit', largeLimit.stdout);
try { await run({ cmd: 'sh', args: ['-c', 'exit 9'] }); } catch (error) { console.log('checked', error.exitCode); }
try { await run({ cmd: 'sh', args: ['-c', 'printf 12345'], maxOutputBytes: 3 }); } catch (error) { console.log('limited', error.message); }
EOF
process_actual=$(HAO_CYNA_TEST=works "$runtime" "$fixture_dir/process.ts")
process_expected=$(printf 'env works\nrun hello warn 0\njson 42\nunchecked 7\nsignaled null 15\ncwd /private/tmp\nlargeLimit ok\nchecked 9\nlimited process output exceeds maxOutputBytes')
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
