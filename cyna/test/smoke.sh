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
for args in ([], ['jupyter', 'unknown'], ['test'], ['test', '--grep']):
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
python3 - "$runtime" "$fixture_dir" <<'PY'
from pathlib import Path
import subprocess, sys
path = Path(sys.argv[2]) / 'oversize.ts'
path.write_bytes(b' ' * (10 * 1024 * 1024 + 1))
result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
assert result.returncode == 1 and result.stdout == '' and result.stderr == 'StreamTooLong\n', result
result = subprocess.run([sys.argv[1], str(Path(sys.argv[2]) / 'missing.ts')],
    capture_output=True, text=True)
assert result.returncode == 1 and result.stdout == '' and result.stderr == 'FileNotFound\n', result
empty = Path(sys.argv[2]) / 'empty-tests'
empty.mkdir()
result = subprocess.run([sys.argv[1], 'test', str(empty)], capture_output=True, text=True)
assert result.returncode == 0 and result.stdout == '' and '0 loaded, 0 failed, 0 total' in result.stderr, result
dotenv = Path(sys.argv[2]) / 'oversize.env'
dotenv.write_bytes(b'#' * (1024 * 1024 + 1))
import os
result = subprocess.run([sys.argv[1], str(Path(sys.argv[2]) / 'main.ts')],
    env={**os.environ, 'DOTENV': str(dotenv)}, capture_output=True, text=True)
assert result.returncode == 1 and 'Unable to load dotenv file' in result.stdout, result
PY
cyna_dir=$(CDPATH= cd -- "$(dirname -- "$(command -v cyna)")/.." && pwd -P)
clang -I "$repo_root/include" -I "$repo_root/cyna/.deps/install/include" "$repo_root/cyna/test/embed_consumer.c" \
    "$repo_root/cyna/embed/build/libhao-cyna-embed.a" \
    -L "$cyna_dir/targets/aarch64-apple-darwin/lib" -lcyna_std -lcyna \
    -L "$repo_root/cyna/.deps/install/lib" -lquickjs -luv \
    -L "$repo_root/libs/transpiler/target/release" -lhao_transpiler \
    -L /opt/homebrew/lib -lcurl -lffi -lzmq -lcrypto -o "$fixture_dir/embed-consumer" 2> "$fixture_dir/embed-link.log"
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$fixture_dir/embed-consumer" "$repo_root/cyna/build/modules" 2> "$fixture_dir/embed-error.log")" = '42'
clang -I /opt/homebrew/include "$repo_root/cyna/test/jupyter_wire_test.c" \
    "$repo_root/cyna/src/jupyter/zmq.c" "$repo_root/cyna/src/runtime_allocator.c" \
    -L /opt/homebrew/lib -lzmq -lcrypto \
    -o "$fixture_dir/jupyter-wire-test"
test "$("$fixture_dir/jupyter-wire-test")" = 'wire ok'
clang -I /opt/homebrew/include "$repo_root/cyna/test/jupyter_kernel_test.c" \
    -L /opt/homebrew/lib -lzmq -lcrypto -o "$fixture_dir/jupyter-kernel-test"
test "$("$fixture_dir/jupyter-kernel-test" "$runtime")" = 'kernel ok'
test "$("$fixture_dir/jupyter-kernel-test" "$runtime" --shared)" = 'kernel ok'
HAO_JUPYTER_KERNEL_DIR="$fixture_dir/kernels/hao" "$runtime" jupyter install > "$fixture_dir/kernelspec-output"
HAO_JUPYTER_KERNEL_DIR="$fixture_dir/kernels/hao" "$runtime" jupyter install ignored > "$fixture_dir/kernelspec-extra-output"
test "$(cat "$fixture_dir/kernelspec-output")" = "$(cat "$fixture_dir/kernelspec-extra-output")"
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
cyna build "$repo_root/cyna/checks/jupyter-connection" --output "$fixture_dir/jupyter-connection-check" > "$fixture_dir/jupyter-build.log" 2>&1
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-connection.json")" = "$(printf 'tcp://127.0.0.1:57503\n\nhmac-sha256')"
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-explicit.json")" = "$(printf 'ipc://0.0.0.0:1\nsecret\nhmac-sha256')"
cat > "$fixture_dir/jupyter-exponent-port.json" <<'EOF'
{"shell_port":1e0,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5}
EOF
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-exponent-port.json")" = "$(printf 'tcp://127.0.0.1:1\n\nhmac-sha256')"
if "$fixture_dir/jupyter-connection-check" "$fixture_dir/main.ts" > "$fixture_dir/jupyter-invalid.log" 2>&1; then
    exit 1
fi
cat > "$fixture_dir/jupyter-invalid-port.json" <<'EOF'
{"shell_port":65536,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5}
EOF
if "$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-invalid-port.json" > "$fixture_dir/jupyter-invalid.log" 2>&1; then
    exit 1
fi
python3 - "$fixture_dir/jupyter-oversized.json" <<'PY'
import sys
with open(sys.argv[1], 'w') as output:
    output.write('{"shell_port":1,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5,"padding":"')
    output.write('x' * (64 * 1024))
    output.write('"}')
PY
if "$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-oversized.json" > "$fixture_dir/jupyter-invalid.log" 2>&1; then
    exit 1
fi
python3 - "$fixture_dir/jupyter-limit.json" <<'PY'
import sys
prefix = '{"shell_port":1,"control_port":2,"iopub_port":3,"stdin_port":4,"hb_port":5,"padding":"'
suffix = '"}'
with open(sys.argv[1], 'w') as output:
    output.write(prefix + 'x' * (64 * 1024 - len(prefix) - len(suffix)) + suffix)
PY
test "$("$fixture_dir/jupyter-connection-check" "$fixture_dir/jupyter-limit.json")" = "$(printf 'tcp://127.0.0.1:1\n\nhmac-sha256')"
configured_actual=$(RUNTIME_QJS_STACK_SIZE=16777216 RUNTIME_QJS_GC_THRESHOLD=1048576 RUNTIME_LIBUV_THREADPOOL_SIZE=4 "$runtime" "$fixture_dir/main.ts")
test "$configured_actual" = "$expected"
test "$(RUNTIME_TELEMETRY_CONSOLE=OFF "$runtime" "$fixture_dir/main.ts")" = "$expected"
test "$(RUNTIME_QJS_STACK_SIZE=+16777216 "$runtime" "$fixture_dir/main.ts")" = "$expected"
test "$(RUNTIME_TELEMETRY_CONSOLE=0 RUNTIME_TELEMETRY_CONSOLE_PORT=+0 "$runtime" "$fixture_dir/main.ts")" = "$expected"
test "$(RUNTIME_TELEMETRY_CONSOLE=0 RUNTIME_TELEMETRY_CONSOLE_PORT=-00 "$runtime" "$fixture_dir/main.ts")" = "$expected"
test "$(RUNTIME_TELEMETRY_CONSOLE=0 RUNTIME_TELEMETRY_CONSOLE_PORT=+1 "$runtime" "$fixture_dir/main.ts")" = "$expected"
if RUNTIME_QJS_STACK_SIZE=invalid "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/config.stdout" 2> "$fixture_dir/config.stderr"; then
    exit 1
fi
if RUNTIME_QJS_STACK_SIZE= "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/config.stdout" 2> "$fixture_dir/config.stderr"; then
    echo 'expected an explicitly empty stack size to fail' >&2
    exit 1
fi
if RUNTIME_QJS_STACK_SIZE="$(printf '\t16777216')" "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/config.stdout" 2> "$fixture_dir/config.stderr"; then
    echo 'expected leading whitespace in stack size to fail' >&2
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
python3 - "$fixture_dir/whitespace.env" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'HAO_DOTENV_TEST=loaded\x0b#comment\n')
PY
printf "import { getEnv } from 'std:process'; console.log(JSON.stringify(getEnv('HAO_DOTENV_TEST')));\n" > "$fixture_dir/dotenv-whitespace.ts"
test "$(DOTENV="$fixture_dir/whitespace.env" "$runtime" "$fixture_dir/dotenv-whitespace.ts")" = '"loaded\u000b"'
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
const first = Object.getOwnPropertyDescriptor(native.pair('a', 'b'), '0');
console.log(first?.writable, first?.enumerable, first?.configurable);
const sparse = [];
sparse.length = 2147483648;
console.log(native.arrayLength(['a', 'b']), native.arrayLength(sparse));
console.log(native.invalidHandleProbe());
for (const args of [[], [1], [Symbol('x'), 2], [{ valueOf() { throw new Error('coercion failed'); } }, 2]]) {
  try { native.add(...args); }
  catch (error) { console.log(error.name, error.message); }
}
for (const value of [null, 1, Symbol('x'), [], [1, 2]]) console.log(native.arrayLength(value));
EOF
addon_actual=$("$runtime" "$fixture_dir/addon.ts")
test "$addon_actual" = "$(printf 'hao 5 a,b extra\nfalse true false\n2 -1\n15\nTypeError add expects two numbers\nTypeError add expects two numbers\nTypeError add expects two numbers\nTypeError add expects two numbers\n-1\n0\n0\n0\n2')"

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
printf "console.log(Symbol('x'));\n" > "$fixture_dir/console-symbol.ts"
test "$("$runtime" "$fixture_dir/console-symbol.ts")" = 'Symbol(x)'

printf "import fs from 'std:fs'; const path = '%s/data.txt'; console.log(fs.existsSync(path)); fs.writeFileSync(path, 'hello'); console.log(fs.existsSync(path), fs.readFileSync(path), fs.statSync(path).size);\n" "$fixture_dir" > "$fixture_dir/filesystem.ts"
filesystem_actual=$("$runtime" "$fixture_dir/filesystem.ts")
filesystem_expected=$(printf 'false\ntrue hello 5')
test "$filesystem_actual" = "$filesystem_expected"
cat > "$fixture_dir/filesystem-long-name.ts" <<'EOF'
import { existsSync } from 'std:fs';
console.log(existsSync('a'.repeat(256)));
console.log(existsSync('a'.repeat(1023)));
EOF
test "$("$runtime" "$fixture_dir/filesystem-long-name.ts")" = "$(printf 'false\nfalse')"
cat > "$fixture_dir/filesystem-args.ts" <<'EOF'
import { existsSync, readFileSync, statSync, writeFileSync } from 'std:fs';
const coercionFailure = { toString() { throw new Error('coercion failed'); } };
for (const [name, call] of [
  ['existsSync', (value: unknown) => existsSync(value as string)],
  ['readFileSync', (value: unknown) => readFileSync(value as string)],
  ['statSync', (value: unknown) => statSync(value as string)],
  ['writeFileSync', (value: unknown) => writeFileSync(value as string, 'x')],
] as const) {
  for (const value of [Symbol('path'), coercionFailure]) {
    try { call(value); } catch (error) { console.log(error.name, error.message); }
  }
}
try { writeFileSync('/tmp/unused-hao-path', Symbol('data') as unknown as string); }
catch (error) { console.log(error.name, error.message); }
EOF
test "$("$runtime" "$fixture_dir/filesystem-args.ts")" = "$(cat <<'EOF'
TypeError existsSync expects a path
TypeError existsSync expects a path
TypeError readFileSync expects a path
TypeError readFileSync expects a path
TypeError statSync expects a path
TypeError statSync expects a path
TypeError writeFileSync expects a path
TypeError writeFileSync expects a path
TypeError writeFileSync expects data
EOF
)"
if [ "$(id -u)" -ne 0 ]; then
    printf 'hidden' > "$fixture_dir/unreadable.txt"
    chmod 000 "$fixture_dir/unreadable.txt"
    printf "import { statSync } from 'std:fs'; try { statSync('%s/unreadable.txt'); } catch (error) { console.log(error.name, error.message); }\n" "$fixture_dir" > "$fixture_dir/filesystem-unreadable.ts"
    test "$("$runtime" "$fixture_dir/filesystem-unreadable.ts")" = 'InternalError failed to stat file'
fi
printf 'a\000b' > "$fixture_dir/external-nul.txt"
printf "import { readFileSync, writeFileSync, statSync } from 'std:fs'; writeFileSync('%s/written-nul.txt', 'a\\\\0b'); console.log(statSync('%s/written-nul.txt').size, readFileSync('%s/external-nul.txt').length);\n" "$fixture_dir" "$fixture_dir" "$fixture_dir" > "$fixture_dir/filesystem-nul.ts"
test "$("$runtime" "$fixture_dir/filesystem-nul.ts")" = '1 1'
python3 - "$fixture_dir/oversize-read.bin" <<'PY'
import sys
with open(sys.argv[1], 'wb') as output:
    output.truncate(100 * 1024 * 1024 + 1)
PY
printf "import { readFileSync } from 'std:fs'; try { readFileSync('%s/oversize-read.bin'); } catch (error) { console.log(error.message); }\n" "$fixture_dir" > "$fixture_dir/filesystem-limit.ts"
test "$("$runtime" "$fixture_dir/filesystem-limit.ts")" = 'failed to read file'

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

cat > "$fixture_dir/console-inspect.ts" <<'EOF'
console.log({ value: 3 }, [1, 2]);
console.error('nul\0kept');
EOF
python3 - "$runtime" "$fixture_dir/console-inspect.ts" <<'PY'
import subprocess, sys
result = subprocess.run(sys.argv[1:], capture_output=True, check=True)
assert result.stdout == b'{ value: 3 } [ 1, 2 ]\n', result.stdout
assert result.stderr == b'nul\0kept\n', result.stderr
PY

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
const manualBody = await get('http://127.0.0.1:$server_port/redirect-with-body', { redirect: 'manual' });
console.log(manualBody.status, manualBody.text());
try { await get('http://127.0.0.1:$server_port/large', { maxBytes: 10 }); } catch (error) { console.log(error.message); }
EOF
http_actual=$("$runtime" "$fixture_dir/http.ts")
http_expected=$(printf '200 /json?q=hello%%20world application/json\n{"answer":42}\n0,1,2,255\n302 /large\n302 redirect body\nhttp response exceeds maxBytes')
test "$http_actual" = "$http_expected"
cat > "$fixture_dir/http-native-body.ts" <<EOF
import { requestNative } from 'std:http/native';
const url = 'http://127.0.0.1:$server_port/echo';
const first = await requestNative({ url, method: 'POST', headers: [],
  bodyText: 'text', bodyBytes: new Uint8Array([98, 121, 116, 101, 115]) });
const second = await requestNative({ url, method: 'POST',
  headers: [['Content-Type', 'application/custom']], bodyText: 'text' });
console.log(JSON.parse(first.bodyText).body, JSON.parse(first.bodyText).contentType);
console.log(JSON.parse(second.bodyText).body, JSON.parse(second.bodyText).contentType);
EOF
test "$("$runtime" "$fixture_dir/http-native-body.ts")" = "$(printf 'bytes null\ntext application/custom')"
cat > "$fixture_dir/http-native-limits.ts" <<'EOF'
import { requestNative } from 'std:http/native';
for (const maxBytes of [0, 0.5, 1.5, Infinity, NaN]) {
  try {
    await requestNative({ url: 'http://127.0.0.1:1/', method: 'GET', headers: [], maxBytes });
    console.log('accepted');
  } catch (error) {
    console.log(error.name, error.message);
  }
}
EOF
test "$("$runtime" "$fixture_dir/http-native-limits.ts")" = "$(printf 'TypeError http.request options are invalid\n%.0s' 1 2 3 4 5)"
cat > "$fixture_dir/http-native-options.ts" <<'EOF'
import { requestNative } from 'std:http/native';
const base: any = { url: 'http://127.0.0.1:1/', method: 'GET', headers: [] };
for (const override of [
  { method: 'BOGUS' }, { method: 'get' }, { downloadPath: '' },
  { method: 'POST', downloadPath: '/tmp/hao-invalid-download' },
  { downloadPath: '/tmp/hao-invalid-download', bodyText: 'x' },
  { downloadPath: '/tmp/hao-invalid-download', bodyBytes: new Uint8Array([1]) },
  { headers: 3 }, { headers: [5] }, { headers: { length: -1 } },
]) {
  try { await requestNative({ ...base, ...override }); console.log('accepted'); }
  catch (error) { console.log(error.name, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/http-native-options.ts")" = "$(printf 'TypeError http.request options are invalid\n%.0s' 1 2 3 4 5 6 7 8 9)"
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

test_summary=$("$runtime" test "$repo_root/test/e2e/test" 2>&1)
case "$test_summary" in *'Tests:'*'31 passed, 0 failed, 7 skipped'*) ;; *) exit 1 ;; esac
cat > "$fixture_dir/explicit.ts" <<'EOF'
import { test, expect } from 'std:test';
test('explicit file', () => expect(2 + 2).toBe(4));
EOF
test "$("$runtime" test "$fixture_dir/explicit.ts" 2>&1 | sed -n 's/.*Tests:.*\(1 passed, 0 failed, 0 skipped\).*/\1/p')" = '1 passed, 0 failed, 0 skipped'
cat > "$fixture_dir/z-order.test.ts" <<'EOF'
import { test } from 'std:test';
test('z order', () => {});
EOF
cat > "$fixture_dir/a-order.test.ts" <<'EOF'
import { test } from 'std:test';
test('a order', () => {});
EOF
order_actual=$(RUNTIME_TEST_REPORTER=plain "$runtime" test "$fixture_dir/z-order.test.ts" "$fixture_dir/a-order.test.ts" 2>&1 | sed -n 's/.*✓ \(.*\) (.*/\1/p')
order_expected=$(printf 'a order\nz order')
test "$order_actual" = "$order_expected"
python3 - "$runtime" "$repo_root/test/e2e/runtime/hello.test.ts" <<'PY'
import os, subprocess, sys
result = subprocess.run([sys.argv[1], 'test', sys.argv[2]], env=dict(os.environ, RUNTIME_TEST_REPORTER='ansi'),
                        capture_output=True, text=True, check=True)
assert '\x1b[32m✓\x1b[0m' in result.stderr
assert 'Time:' in result.stderr
assert '1 passed, 0 failed, 0 skipped' in result.stderr
PY
cat > "$fixture_dir/expected-failure.test.ts" <<'EOF'
import { test, expect } from 'std:test';
test('failure changes exit status', () => expect(1).toBe(2));
EOF
if "$runtime" test "$fixture_dir/expected-failure.test.ts" > "$fixture_dir/test-output" 2> "$fixture_dir/stderr"; then
    echo 'expected a failing test to exit with an error' >&2
    exit 1
fi
grep -q '0 passed, 1 failed, 0 skipped' "$fixture_dir/stderr"
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
grep -q '0 passed, 2 failed, 2 skipped' "$fixture_dir/hook-stderr"
grep -q 'outer cleanup' "$fixture_dir/hook-output"
if grep -q 'inner cleanup\|body should not run' "$fixture_dir/hook-output"; then
    exit 1
fi
cat > "$fixture_dir/multiple-hook-failures.test.ts" <<'EOF'
import { describe, test, afterEach, afterAll } from 'std:test';
describe('multi', () => {
  afterEach(() => { throw Error('cleanup one'); });
  afterEach(() => { throw Error('cleanup two'); });
  afterAll(() => { throw Error('suite cleanup'); });
  test('body failure', () => { throw null; });
  test('body pass', () => {});
});
EOF
if RUNTIME_TEST_REPORTER=plain "$runtime" test "$fixture_dir/multiple-hook-failures.test.ts" > "$fixture_dir/multi-out" 2> "$fixture_dir/multi-err"; then
    exit 1
fi
grep -q '0 passed, 3 failed, 0 skipped' "$fixture_dir/multi-err"
grep -q 'test failed: null' "$fixture_dir/multi-err"
grep -q 'afterEach failed: cleanup one' "$fixture_dir/multi-err"
grep -q 'afterEach failed: cleanup two' "$fixture_dir/multi-err"
grep -q 'afterAll failed: suite cleanup' "$fixture_dir/multi-err"
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
capture_summary=$("$runtime" test "$fixture_dir/capture.test.ts" 2>&1)
case "$capture_summary" in *'Tests:'*'2 passed, 0 failed, 0 skipped'*) ;; *) exit 1 ;; esac
telemetry_summary=$("$runtime" test "$repo_root/test/e2e/telemetry/metrics.test.ts" 2>&1)
case "$telemetry_summary" in *'Tests:'*'4 passed, 0 failed, 0 skipped'*) ;; *) exit 1 ;; esac
cat > "$fixture_dir/telemetry-console.ts" <<'EOF'
import { counter, trace } from 'std:telemetry';
import { startRootTraceNative, addTraceEventNative, endTraceNative } from 'std:telemetry/native';
counter({ scope: 'fixture', name: 'requests' }).add(3);
trace('fixture-trace', () => {});
const span = startRootTraceNative('fixture-event', { method: 'GET' });
addTraceEventNative(span, 'fixture-received', { bytes: 42 });
endTraceNative(span);
setTimeout(() => {}, 1500);
EOF
python3 - "$runtime" "$fixture_dir/telemetry-console.ts" <<'PY'
import json, os, re, subprocess, sys, urllib.request
for flag in ('1', 'true', 'yes', 'on'):
    env = dict(os.environ, RUNTIME_TELEMETRY_CONSOLE=flag, RUNTIME_TELEMETRY_CONSOLE_PORT='00')
    process = subprocess.Popen([sys.argv[1], sys.argv[2]], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        line = process.stderr.readline()
        match = re.search(r'http://127\.0\.0\.1:(\d+)/', line)
        assert match, (flag, line)
        base = 'http://127.0.0.1:' + match.group(1)
        def get(path):
            with urllib.request.urlopen(base + path, timeout=2) as response:
                return response.read().decode()
        assert json.loads(get('/api/health')) == {'ok': True}
        metrics = json.loads(get('/api/metrics'))
        assert any(metric['scope'] == 'fixture' and metric['value'] == 3 for metric in metrics)
        memory_names = {metric['name'] for metric in metrics if metric['scope'] == 'runtime.memory'}
        assert {
            'allocator_active_bytes', 'allocator_peak_bytes',
            'allocator_allocated_bytes_total', 'allocator_freed_bytes_total',
            'allocator_allocation_count', 'allocator_free_count',
            'resident_bytes', 'physical_footprint_bytes',
            'resident_peak_bytes', 'physical_footprint_peak_bytes',
        } <= memory_names
        traces = json.loads(get('/api/traces?since=0&limit=10'))
        assert [record['kind'] for record in traces['records'] if record['name'] == 'fixture-trace'] == ['span_start', 'span_end']
        assert [record['kind'] for record in traces['records'] if record['name'] in ('fixture-event', 'fixture-received')] == ['span_start', 'event', 'span_end']
        assert next(record for record in traces['records'] if record['name'] == 'fixture-received')['attributes']['bytes'] == 42
        roots = [record for record in traces['records'] if record['kind'] == 'span_start']
        assert len(roots) == 2 and roots[0]['trace_id'] != roots[1]['trace_id']
        assert all(re.fullmatch('[0-9a-f]{32}', record['trace_id']) and
                   re.fullmatch('[0-9a-f]{16}', record['span_id']) for record in traces['records'])
        later = json.loads(get('/api/traces?since=1&limit=1'))
        assert later['records'][0]['sequence'] == 2 and later['next_cursor'] == 2
        assert '<title>Hao Telemetry</title>' in get('/')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
PY
if RUNTIME_TELEMETRY_CONSOLE=maybe "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/invalid-console.stdout" 2> "$fixture_dir/invalid-console.stderr"; then
    exit 1
fi
if RUNTIME_TELEMETRY_CONSOLE_PORT=65536 "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/invalid-port.stdout" 2> "$fixture_dir/invalid-port.stderr"; then
    exit 1
fi
cat > "$fixture_dir/telemetry-timer.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('root', () => setTimeout(() => {
  trace('child', () => {});
  const records = snapshotTraceRecordsNative().records;
  console.log(records[0].name, records[2].name, records[2].parent_span_id === records[0].span_id);
}, 1));
EOF
cat > "$fixture_dir/telemetry-handles.ts" <<'EOF'
import telemetry, { startTrace, startSpan } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
const root = startTrace('public-root');
root.end();
telemetry.startSpan('public-span').end('err');
console.log(snapshotTraceRecordsNative().records.map(record => `${record.name}:${record.status}`).join(','));
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-handles.ts")" = 'public-root:unset,public-root:ok,public-span:unset,public-span:err'
cat > "$fixture_dir/telemetry-native-names.ts" <<'EOF'
import { startTraceNative, startRootTraceNative, endTraceNative } from 'std:telemetry/native';
for (const name of [42, '', 'x'.repeat(97)]) {
  try { const id = startTraceNative(name); console.log('ok', id); endTraceNative(id); }
  catch (error) { console.log(error.name, error.message); }
}
try { startRootTraceNative(); } catch (error) { console.log(error.name, error.message); }
try { startRootTraceNative('x'.repeat(97)); } catch (error) { console.log(error.name, error.message); }
try { startTraceNative(Symbol('name')); } catch (error) { console.log(error.name, error.message); }
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-native-names.ts")" = "$(printf 'ok 1\nok 2\nInternalError failed to start trace span\nTypeError startRootTrace requires a name\nInternalError failed to start root trace span\nTypeError trace name must be a string')"
cat > "$fixture_dir/telemetry-native-ids.ts" <<'EOF'
import { startTraceNative, enterTraceNative, exitTraceNative, endTraceNative,
  snapshotTraceRecordsNative } from 'std:telemetry/native';
const id = startTraceNative('coerced');
const scope = enterTraceNative(String(id));
exitTraceNative(String(scope));
endTraceNative(String(id), 7);
console.log(snapshotTraceRecordsNative().records.at(-1).status);
for (const invoke of [() => enterTraceNative(99), () => exitTraceNative(99),
  () => endTraceNative(99), () => enterTraceNative(-1), () => exitTraceNative(),
  () => endTraceNative(99, Symbol('status'))]) {
  try { invoke(); } catch (error) { console.log(error.name, error.message); }
}
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-native-ids.ts")" = "$(printf 'ok\nInternalError failed to enter trace span\nInternalError failed to exit trace span\nInternalError failed to end trace span\nTypeError trace span id must be a non-negative integer\nTypeError exitTrace requires a scope id\nTypeError trace status must be a string')"
cat > "$fixture_dir/telemetry-disabled.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('disabled', () => {});
console.log(snapshotTraceRecordsNative().records.length);
EOF
test "$("$runtime" "$fixture_dir/telemetry-disabled.ts")" = '0'
cat > "$fixture_dir/telemetry-clock.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('clock', () => {});
const records = snapshotTraceRecordsNative().records;
console.log(records.length, records[0].timestamp_ns > 0,
  records[1].timestamp_ns >= records[0].timestamp_ns,
  records[0].timestamp_ns < Date.now() * 1000000 / 10);
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-clock.ts")" = '2 true true true'
cat > "$fixture_dir/telemetry-event.ts" <<'EOF'
import { startRootTraceNative, addTraceEventNative, endTraceNative,
  snapshotTraceRecordsNative } from 'std:telemetry/native';
const id = startRootTraceNative('request', { method: 'GET', secure: true });
addTraceEventNative(id, 'received', { bytes: 42, valid: true });
endTraceNative(id);
const records = snapshotTraceRecordsNative().records;
console.log(records.map(record => record.kind).join(','), records[0].attributes.method,
  records[1].attributes.bytes, records[1].parent_span_id === '0000000000000000');
records[0].attributes.method = 'changed';
console.log(snapshotTraceRecordsNative().records[0].attributes.method);
for (const attributes of [{ value: 'x'.repeat(257) },
  Object.fromEntries(Array.from({ length: 17 }, (_, i) => ['key' + i, i]))]) {
  try { startRootTraceNative('invalid', attributes); } catch (error) { console.log('rejected'); }
}
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-event.ts")" = "$(printf 'span_start,event,span_end GET 42 true\nGET\nrejected\nrejected')"
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-timer.ts")" = 'root child true'
cat > "$fixture_dir/telemetry-interleave.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
await Promise.all(['left', 'right'].map(name => trace(name, async () => {
  await new Promise(resolve => setTimeout(resolve, name === 'left' ? 8 : 2));
  trace(`${name}-child`, () => {});
})));
const starts = snapshotTraceRecordsNative().records.filter(record => record.kind === 'span_start');
for (const name of ['left', 'right']) {
  const parent = starts.find(record => record.name === name)!;
  const child = starts.find(record => record.name === `${name}-child`)!;
  console.log(child.parent_span_id === parent.span_id, child.trace_id === parent.trace_id);
}
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-interleave.ts")" = "$(printf 'true true\ntrue true')"
cat > "$fixture_dir/telemetry-http.ts" <<'EOF'
import { serve, get } from 'std:http';
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
const server = serve({ port: 0, handler: async (request: any) => {
  await new Promise(resolve => setTimeout(resolve, request.url === '/left' ? 4 : 1));
  return { body: 'ok' };
} });
await Promise.all(['left', 'right'].map(name => trace(name, async () => {
  await get(`http://127.0.0.1:${server.port}/${name}`);
  trace(`${name}-child`, () => {});
})));
await trace('failure', async () => {
  try { await get('http://127.0.0.1:1/unreachable'); }
  catch { trace('failure-child', () => {}); }
});
server.close();
const records = snapshotTraceRecordsNative().records;
for (const name of ['left', 'right', 'failure']) {
  const parent = records.find(record => record.kind === 'span_start' && record.name === name);
  const child = records.find(record => record.kind === 'span_start' && record.name === `${name}-child`);
  console.log(parent?.trace_id === child?.trace_id, parent?.span_id === child?.parent_span_id);
}
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-http.ts")" = "$(printf 'true true\ntrue true\ntrue true')"
cat > "$fixture_dir/telemetry-ring.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
for (let i = 0; i < 260; i++) trace(`span-${i}`, () => {});
const page = snapshotTraceRecordsNative(1, 3);
console.log(page.missed, page.records.length, page.records[0].sequence, page.next_cursor);
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-ring.ts")" = 'false 3 2 4'
test "$(RUNTIME_TELEMETRY_CONSOLE=1 RUNTIME_TELEMETRY_TRACE_RECORDS=8 "$runtime" "$fixture_dir/telemetry-ring.ts")" = 'true 3 513 515'
cat > "$fixture_dir/telemetry-active-parent.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('root', () => trace('active-child', () => {
  for (let i = 0; i < 520; i++) trace(`finished-${i}`, () => {});
  trace('grandchild', () => {});
  const records = snapshotTraceRecordsNative(0, 2000).records;
  const root = records.find(record => record.name === 'root')!;
  const child = records.find(record => record.name === 'active-child')!;
  const grandchild = records.find(record => record.name === 'grandchild')!;
  console.log(grandchild.trace_id === root.trace_id, grandchild.parent_span_id === child.span_id);
}));
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-active-parent.ts")" = 'true true'
cat > "$fixture_dir/telemetry-ended-parent.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';
trace('root', () => trace('ended-child', () => setTimeout(() => {
  trace('delayed-grandchild', () => {});
  const records = snapshotTraceRecordsNative(0, 2000).records;
  const root = records.find(record => record.name === 'root')!;
  const child = records.find(record => record.name === 'ended-child')!;
  const grandchild = records.find(record => record.name === 'delayed-grandchild')!;
  console.log(grandchild.trace_id === root.trace_id, grandchild.parent_span_id === child.span_id);
}, 1)));
for (let i = 0; i < 520; i++) trace(`finished-${i}`, () => {});
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/telemetry-ended-parent.ts")" = 'true true'
if RUNTIME_TELEMETRY_TRACE_RECORDS=0 "$runtime" "$fixture_dir/main.ts" > "$fixture_dir/trace-config.stdout" 2> "$fixture_dir/trace-config.stderr"; then
    echo 'expected zero trace capacity to fail' >&2
    exit 1
fi
ffi_summary=$("$runtime" test "$repo_root/test/e2e/ffi" 2>&1)
case "$ffi_summary" in *'Tests:'*'7 passed, 0 failed, 0 skipped'*) ;; *) exit 1 ;; esac
error_summary=$("$runtime" test "$repo_root/test/e2e/runtime/errors.test.ts" 2>&1)
case "$error_summary" in *'Tests:'*'2 passed, 0 failed, 0 skipped'*) ;; *) exit 1 ;; esac
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
if load_result=$(RUNTIME_TEST_REPORTER=plain "$runtime" test "$fixture_dir/broken.test.ts" "$fixture_dir/after-broken.test.ts" 2>&1); then
    echo 'expected a failed test file to return failure' >&2
    exit 1
fi
case "$load_result" in
    *'✕ module '*'broken.test.ts'*'load failed'*'1 loaded, 1 failed, 2 total'*'2 passed, 1 failed, 0 skipped'*) ;;
    *) echo "$load_result" >&2; exit 1 ;;
esac
python3 - "$runtime" "$fixture_dir/broken.test.ts" <<'PY'
import os, subprocess, sys
result = subprocess.run([sys.argv[1], 'test', sys.argv[2]],
    env=dict(os.environ, RUNTIME_TEST_REPORTER='ansi'), capture_output=True, text=True)
assert result.returncode == 1 and '\x1b[31m✕\x1b[0m module ' in result.stderr, result
PY
cat > "$fixture_dir/syntax-error.test.ts" <<'EOF'
import { test } from 'std:test';
test('must not register', () => {});
const = ;
EOF
if "$runtime" test "$fixture_dir/syntax-error.test.ts" > "$fixture_dir/syntax-stdout" 2> "$fixture_dir/syntax-stderr"; then
    exit 1
fi
test ! -s "$fixture_dir/syntax-stdout"
test "$(tail -1 "$fixture_dir/syntax-stderr")" = 'TranspileFailed'
python3 - "$fixture_dir/oversize.test.ts" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b' ' * (10 * 1024 * 1024 + 1))
PY
if "$runtime" test "$fixture_dir/oversize.test.ts" > "$fixture_dir/oversize-stdout" 2> "$fixture_dir/oversize-stderr"; then
    exit 1
fi
test ! -s "$fixture_dir/oversize-stdout"
test "$(tail -1 "$fixture_dir/oversize-stderr")" = 'StreamTooLong'
cat > "$fixture_dir/grep-suite.test.ts" <<'EOF'
import { describe, test } from 'std:test';
describe('needle suite', () => test('plain case', () => { throw Error('suite name must not match grep'); }));
EOF
grep_result=$("$runtime" test --grep needle "$fixture_dir/grep-suite.test.ts" 2>&1)
case "$grep_result" in
    *'0 passed, 0 failed, 1 skipped'*) ;;
    *) echo "$grep_result" >&2; exit 1 ;;
esac
cat > "$fixture_dir/ffi-mixed.ts" <<'EOF'
import { dlopen } from 'std:ffi';
const math = dlopen('m', { ldexp: { args: ['f64', 'i32'], returns: 'f64' } });
console.log(math.ldexp(1.5, 3));
math.close();
EOF
test "$("$runtime" "$fixture_dir/ffi-mixed.ts")" = 12
cat > "$fixture_dir/ffi-closed.ts" <<'EOF'
import { openNative, callNative, closeNative } from 'std:ffi/native';
const handle = openNative('m', { cos: { args: ['f64'], returns: 'f64' } });
console.log(callNative(handle, 'cos', [0]));
closeNative(handle);
closeNative(handle);
try { callNative(handle, 'cos', [0]); } catch (error) { console.log(error.name, error.message); }
EOF
test "$("$runtime" "$fixture_dir/ffi-closed.ts")" = "$(printf '1\nTypeError FFI: library has been closed')"
cat > "$fixture_dir/ffi-arity.ts" <<'EOF'
import { openNative, callNative, closeNative } from 'std:ffi/native';
for (const invoke of [() => openNative('m'), () => callNative(0, 'cos'), () => closeNative(), () => closeNative(-1)]) {
  try { invoke(); } catch (error) { console.log(error.name, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-arity.ts")" = "$(printf 'TypeError dlopen requires 2 arguments: library name and descriptor\nTypeError ffi.callNative requires handle, symbol, and args\nTypeError ffi.closeNative requires a handle\nTypeError FFI: invalid library handle')"
cat > "$fixture_dir/ffi-missing-symbol.ts" <<'EOF'
import { openNative } from 'std:ffi/native';
try { openNative('m', { hao_missing_symbol: { args: [], returns: 'void' } }); }
catch (error) { console.log(error.name, error.message); }
EOF
test "$("$runtime" "$fixture_dir/ffi-missing-symbol.ts")" = 'InternalError dlopen: symbol not found'
cat > "$fixture_dir/ffi-search.c" <<'EOF'
#include <stdint.h>
#include <string.h>
int hao_search_value(void) { return 29; }
char hao_char_255(void) { return (char)255; }
char *hao_mutable_char_pointer(void) { static char value[] = "mutable"; return value; }
const char *hao_const_char_pointer(void) { return "constant"; }
void hao_fill_bytes(uint8_t *data, size_t length) { for (size_t i = 0; i < length; ++i) data[i] = (uint8_t)(i + 1); }
uint64_t hao_high_bit(uint64_t value) { return value >> 63; }
uint64_t hao_echo_u64(uint64_t value) { return value; }
uint64_t hao_u64_max(void) { return UINT64_MAX; }
uint64_t hao_u64_mid(void) { return UINT64_C(9007199254740993); }
int8_t hao_echo_i8(int8_t value) { return value; }
uint8_t hao_echo_u8(uint8_t value) { return value; }
float hao_echo_f32(float value) { return value; }
static char hao_long_text[1024 * 1024 + 18];
const char *hao_long_string(void) {
    memset(hao_long_text, 'x', sizeof(hao_long_text) - 1);
    hao_long_text[sizeof(hao_long_text) - 1] = 0;
    return hao_long_text;
}
int hao_make_handle(void **out) { *out = (void *)0x1234; return 0; }
int hao_fail_handle(void **out) { *out = (void *)0x1234; return 5; }
int hao_fail_with_code(int code) { return code ? -1 : 0; }
const char *hao_error_message(int code) { return code == 7 ? "status 7" : "other status"; }
typedef struct HaoBox { int value; } HaoBox;
static HaoBox hao_box = { 37 };
HaoBox *hao_box_open(void) { return &hao_box; }
int32_t hao_box_open_out(HaoBox **out) { *out = &hao_box; return 0; }
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
cat > "$fixture_dir/ffi-c-prepare.ts" <<'EOF'
import { prepareNative, openNative, callNative, closeNative } from 'std:ffi/c/native';
console.log(JSON.stringify(prepareNative('m', 'double sqrt(double x);')));
const opened = openNative('m', 'double sqrt(double x);');
console.log(JSON.stringify({ symbols: opened.symbols, policies: opened.policies }));
closeNative(opened.handle);
console.log(JSON.stringify(prepareNative('x',
  'typedef struct Foo Foo; int32_t hao_open(Foo **out);',
  { functions: { hao_open: { returns: { out: 'out' } } } })));
try { prepareNative('m', 'double sqrt(double x);',
  { functions: { sqrt: { errors: { kind: 'status', ok: 0, code: 'io_error' } } } }); }
catch (error) { console.log(error.name, error.code, error.message); }
try { prepareNative('m', 'double sqrt(double x); double sqrt(double y);'); }
catch (error) { console.log(error.name, error.code, error.message); }
for (const declarations of ['int sum(int a, int b);', 'void set_cb(void (*cb)(int));', 'double sqrt(double x)']) {
  try { prepareNative('m', declarations); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
console.log(JSON.stringify(prepareNative('m', '')));
console.log(JSON.stringify(prepareNative('m', 'typedef struct Foo Foo;')));
for (const declarations of [
  'void f(double a, double a);',
  'typedef struct Foo Foo; typedef struct Foo Foo; void f(void);',
  'Unknown f(void);',
  'void f(double);',
]) {
  try { prepareNative('m', declarations); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
const recursive = 'typedef struct { Foo f; } Foo; double sqrt(Foo *value);';
console.log(JSON.stringify(prepareNative('m', recursive)));
const recursiveLibrary = openNative('m', recursive);
try { callNative(recursiveLibrary.handle, 'sqrt', [{ f: {} }]); }
catch (error) { console.log(error.name, error.code, error.message); }
closeNative(recursiveLibrary.handle);
for (const field of ['void *next', 'Foo *next', 'int32_t value; void *next']) {
  const declaration = `typedef struct { ${field}; } Foo; double sqrt(Foo *value);`;
  console.log(JSON.stringify(prepareNative('m', declaration)));
  const library = openNative('m', declaration);
  try { callNative(library.handle, 'sqrt', [{ value: 1, next: 0 }]); }
  catch (error) { console.log(error.name, error.code, error.message); }
  closeNative(library.handle);
}
for (const [declaration, options] of [
  ['double sqrt(double x);', { functions: { missing: {} } }],
  ['int32_t get(double value);', { functions: { get: { returns: { out: 'missing' } } } }],
  ['int32_t get(double value);', { functions: { get: { returns: { out: 'value' } } } }],
]) {
  try { prepareNative('m', declaration, options); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-prepare.ts")" = "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  '{"descriptor":{"sqrt":{"args":["f64"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}' \
  '{"symbols":["sqrt"],"policies":{"handles":{},"functions":{}}}' \
  '{"descriptor":{"hao_open":{"args":["ptr"],"returns":"i32"}},"policies":{"handles":{},"functions":{"hao_open":{"returns":{"kind":"handle","type":"Foo"}}}}}' \
  'RuntimeError internal prepareNative: failed to build descriptor' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: DuplicateFunctionName' \
  'RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: UnsupportedFeature' \
  'RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: UnsupportedFeature' \
  'RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError' \
  '{"descriptor":{},"policies":{"handles":{},"functions":{}}}' \
  '{"descriptor":{},"policies":{"handles":{},"functions":{}}}' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: DuplicateParamName' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: DuplicateTypeName' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: UnknownNamedType' \
  'RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError' \
  '{"descriptor":{"sqrt":{"args":["ptr"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}' \
  'RuntimeError invalid_arg C: unsupported POD struct layout for runtime marshaling' \
  '{"descriptor":{"sqrt":{"args":["ptr"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}' \
  'RuntimeError invalid_arg C: unsupported POD struct layout for runtime marshaling' \
  '{"descriptor":{"sqrt":{"args":["ptr"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}' \
  'RuntimeError invalid_arg C: unsupported POD struct layout for runtime marshaling' \
  '{"descriptor":{"sqrt":{"args":["ptr"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}' \
  'RuntimeError invalid_arg C: unsupported POD struct layout for runtime marshaling' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: UnknownFunctionOption' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: UnknownOutParam' \
  'RuntimeError invalid_arg prepareNative: declaration lowering failed: OutParamNotPointer')"
cat > "$fixture_dir/ffi-c-policy-errors.ts" <<'EOF'
import { prepareNative } from 'std:ffi/c/native';
for (const [declaration, options] of [
  ['double sqrt(double x);', { functions: { sqrt: { buffers: { missing: { length: 'x', element: 'u8' } } } } }],
  ['void fill(uint8_t *data, size_t len);', { functions: { fill: { buffers: { data: { length: 'missing', element: 'u8' } } } } }],
  ['void fill(uint8_t *data, double len);', { functions: { fill: { buffers: { data: { length: 'len', element: 'u8' } } } } }],
  ['double sqrt(double x);', { search: { strategy: 'bad' } }],
  ['double sqrt(double x);', { search: { paths: [3] } }],
]) {
  try { console.log(JSON.stringify(prepareNative('m', declaration, options))); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-policy-errors.ts")" = "$(cat <<'EOF'
RuntimeError invalid_arg prepareNative: declaration lowering failed: UnknownBufferPointerParam
RuntimeError invalid_arg prepareNative: declaration lowering failed: UnknownBufferLengthParam
RuntimeError invalid_arg prepareNative: declaration lowering failed: BufferLengthNotSizeLike
RuntimeError invalid_arg prepareNative: invalid options: InvalidArgument
{"descriptor":{"sqrt":{"args":["f64"],"returns":"f64"}},"policies":{"handles":{},"functions":{}}}
EOF
)"
cat > "$fixture_dir/ffi-c-options-purity.ts" <<'EOF'
import { prepareNative } from 'std:ffi/c/native';
for (const frozen of [false, true]) {
  const search = { strategy: 'runtime-default', paths: [3] };
  if (frozen) { Object.freeze(search.paths); Object.freeze(search); }
  const result = prepareNative('m', 'double sqrt(double x);', { search });
  console.log(Object.keys(result.descriptor).join(','), typeof search.paths[0], search.paths[0]);
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-options-purity.ts")" = "$(printf 'sqrt number 3\nsqrt number 3')"
cat > "$fixture_dir/ffi-c-syntax-matrix.ts" <<'EOF'
import { prepareNative } from 'std:ffi/c/native';
for (const declaration of [
  'typedef struct { int32_t x:3; } Bits; void f(Bits *b);',
  'void f(struct Foo *x);',
  'typedef struct Foo Bar; void f(Bar *x);',
  'typedef struct { } Empty; void f(Empty *x);',
]) {
  try { console.log(JSON.stringify(prepareNative('m', declaration))); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-syntax-matrix.ts")" = "$(cat <<'EOF'
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: UnsupportedFeature
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: UnsupportedFeature
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: UnsupportedFeature
{"descriptor":{"f":{"args":["ptr"],"returns":"void"}},"policies":{"handles":{},"functions":{}}}
EOF
)"
cat > "$fixture_dir/ffi-c-named-types.ts" <<'EOF'
import { prepareNative, openNative } from 'std:ffi/c/native';
for (const declaration of [
  'void f(void, int32_t x);',
  'void f(void x);',
  'typedef struct { char bytes[4]; } Foo; void f(Foo *x);',
  'typedef struct { volatile int32_t x; } Foo; void f(Foo *x);',
  'static double f(double x);',
  'typedef struct { int32_t x; } Foo; Foo sqrt(void);',
]) {
  try { console.log(JSON.stringify(prepareNative('m', declaration))); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
for (const declaration of [
  'typedef struct { int32_t x; } Foo; Foo sqrt(void);',
  'typedef struct Foo Foo; double sqrt(Foo value);',
]) {
  try { openNative('m', declaration); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-named-types.ts")" = "$(cat <<'EOF'
RuntimeError invalid_arg prepareNative: declaration lowering failed: MissingParamName
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError
RuntimeError invalid_arg prepareNative: unsupported or invalid C declarations: SyntaxError
RuntimeError internal prepareNative: failed to build descriptor
RuntimeError invalid_arg openNative: unsupported function policy in runtime path: UnsupportedFeature
RuntimeError invalid_arg openNative: unsupported function policy in runtime path: UnsupportedFeature
EOF
)"
cat > "$fixture_dir/ffi-c-call-errors.ts" <<'EOF'
import { openNative, callNative, closeNative } from 'std:ffi/c/native';
const library = openNative('m', 'double sqrt(double x);');
for (const [symbol, args] of [['missing', [4]], ['sqrt', []]]) {
  try { callNative(library.handle, symbol, args); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
closeNative(library.handle);
try { callNative(library.handle, 'sqrt', [4]); }
catch (error) { console.log(error.name, error.code, error.message); }
for (const invalid of [0, -1, 'bad']) {
  try { closeNative(invalid); }
  catch (error) { console.log(error.name, error.code, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-c-call-errors.ts")" = "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  'RuntimeError invalid_arg C: unknown symbol' \
  'RuntimeError invalid_arg C: wrong number of arguments' \
  'RuntimeError invalid_arg C: invalid library handle' \
  'RuntimeError invalid_arg C: invalid library handle' \
  'RuntimeError invalid_arg C: invalid library handle' \
  'RuntimeError invalid_arg C: invalid library handle')"
cat > "$fixture_dir/ffi-c-conversion-errors.ts" <<'EOF'
import { openNative, callNative, closeNative } from 'std:ffi/c/native';
import { getEnv } from 'std:process';
const floating = openNative('m', 'double sqrt(double x);');
for (const value of [Symbol('x'), { valueOf() { throw Error('bad conversion') } }]) {
  try { callNative(floating.handle, 'sqrt', [value]); }
  catch (error) { console.log(error.name, error.message); }
}
closeNative(floating.handle);
const path = `${getEnv('HAO_FFI_TEST_PATH')}/libhao_search_fixture.dylib`;
const integer = openNative(path, 'uint64_t hao_echo_u64(uint64_t value);');
try { callNative(integer.handle, 'hao_echo_u64', [Symbol('x')]); }
catch (error) { console.log(error.name, error.message); }
closeNative(integer.handle);
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-c-conversion-errors.ts")" = \
  "$(printf 'TypeError cannot convert symbol to number\nError bad conversion\nTypeError cannot convert symbol to string')"
cat > "$fixture_dir/ffi-c-policy-error.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = `${getEnv('HAO_FFI_TEST_PATH')}/libhao_search_fixture.dylib`;
for (const code of ['io_error', 'bogus']) {
  const library = cdecl(path, 'int32_t hao_fail_with_code(int32_t code);', {
    functions: { hao_fail_with_code: { errors: { kind: 'status', ok: 0, code, message: 'policy failed' } } },
  });
  try { library.hao_fail_with_code(1); }
  catch (error) { console.log(error.name, error.code, error.message); }
  library.close();
}
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-c-policy-error.ts")" = \
  "$(printf 'RuntimeError io_error policy failed\nRuntimeError internal policy failed')"
cat > "$fixture_dir/ffi-terminator.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
for (const declaration of ['double sqrt(double x)', 'double sqrt(double x);']) {
  try {
    const library = cdecl('m', declaration);
    console.log('accepted', library.sqrt(4));
    library.close();
  } catch (_) { console.log('rejected'); }
}
EOF
test "$("$runtime" "$fixture_dir/ffi-terminator.ts")" = "$(printf 'rejected\naccepted 2')"
cat > "$fixture_dir/ffi-native-stack.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
for (const [declaration, nativeName] of [
  ['double sqrt(double x)', 'SyntaxError'],
  ['#include <stdio.h>', 'UnsupportedFeature'],
  ['int printf(const char* fmt, ...);', 'UnsupportedFeature'],
  ['void set_cb(void (*cb)(int));', 'UnsupportedFeature'],
  ['int sum(int a, int b);', 'UnsupportedFeature'],
]) {
  try { cdecl('m', declaration); }
  catch (error) { console.log(typeof error.nativeStack, error.nativeStack?.startsWith(nativeName + '\n')); }
}
EOF
test "$(RUNTIME_NATIVE_STACK_TRACE=1 "$runtime" "$fixture_dir/ffi-native-stack.ts")" = "$(printf 'string true\nstring true\nstring true\nstring true\nstring true')"
test "$(RUNTIME_NATIVE_STACK_TRACE=0 "$runtime" "$fixture_dir/ffi-native-stack.ts")" = "$(printf 'undefined undefined\nundefined undefined\nundefined undefined\nundefined undefined\nundefined undefined')"
cat > "$fixture_dir/ffi-c-missing-symbol.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
try { cdecl('m', 'void hao_missing_symbol(void);'); }
catch (error) {
  console.log(error.name, error.code, error.message, error.nativeStack?.split('\n')[0]);
}
EOF
test "$(RUNTIME_NATIVE_STACK_TRACE=1 "$runtime" "$fixture_dir/ffi-c-missing-symbol.ts")" = \
  'RuntimeError io_error openNative: symbol not found: SymbolNotFound SymbolNotFound'
cat > "$fixture_dir/ffi-char.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = cdecl(`${path}/libhao_search_fixture.dylib`, 'char hao_char_255(void);');
console.log(library.hao_char_255());
library.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-char.ts")" = '255'
cat > "$fixture_dir/ffi-char-pointer.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = cdecl(`${path}/libhao_search_fixture.dylib`,
  'char *hao_mutable_char_pointer(void); const char *hao_const_char_pointer(void);');
console.log(typeof library.hao_mutable_char_pointer(), library.hao_const_char_pointer());
for (const declaration of [
  'char * const hao_mutable_char_pointer(void);',
  'signed char hao_char_255(void);',
  'int hao_search_value(void);',
]) {
  try {
    const candidate = cdecl(`${path}/libhao_search_fixture.dylib`, declaration);
    if (declaration.startsWith('char * const')) {
      console.log(typeof candidate.hao_mutable_char_pointer());
    } else {
      console.log('accepted unsupported type');
    }
    candidate.close();
  } catch (error) {
    if (declaration.startsWith('char * const')) throw error;
    console.log('rejected');
  }
}
library.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-char-pointer.ts")" = "$(printf 'number constant\nnumber\nrejected\nrejected')"
cat > "$fixture_dir/ffi-duplicate.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
for (const declarations of [
  'double sqrt(double value); double sqrt(double value);',
  'typedef struct { double value; } HaoPoint; typedef struct { double value; } HaoPoint; double sqrt(double value);',
  'typedef struct HaoBox HaoBox; typedef struct HaoBox HaoBox; double sqrt(double value);',
  'typedef struct HaoBox HaoBox; typedef struct { double value; } HaoBox; double sqrt(double value);',
  'double pow(double value, double value);',
  'Missing *hao_box_open(void);',
]) {
  try { cdecl(`${path}/libhao_search_fixture.dylib`, declarations); console.log('accepted'); }
  catch { console.log('rejected'); }
}
const forward = cdecl(`${path}/libhao_search_fixture.dylib`,
  'HaoBox *hao_box_open(void); typedef struct HaoBox HaoBox;');
console.log(typeof forward.hao_box_open());
forward.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-duplicate.ts")" = "$(printf 'rejected\nrejected\nrejected\nrejected\nrejected\nrejected\nnumber')"
cat > "$fixture_dir/ffi-policy-validation.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = `${getEnv('HAO_FFI_TEST_PATH')}/libhao_search_fixture.dylib`;
const cases: [string, any][] = [
  ['typedef struct HaoBox HaoBox; void hao_box_close(void *box);',
    { handles: { HaoBox: { close: 'hao_box_close' } } }],
  ['void hao_box_close(void *box);',
    { functions: { hao_box_close: { buffers: { missing: { length: 'box', element: 'u8' } } } } }],
  ['void hao_box_close(void *box);',
    { functions: { hao_box_close: { buffers: { box: { length: 'missing', element: 'u8' } } } } }],
  ['int32_t hao_fail_with_code(int32_t code);',
    { functions: { hao_fail_with_code: { buffers: { code: { length: 'code', element: 'u8' } } } } }],
  ['void hao_fill_bytes(uint8_t *data, size_t length);',
    { functions: { hao_fill_bytes: { buffers: { data: { length: 'length', element: 'bad' } } } } }],
  ['void hao_fill_bytes(uint8_t *data, size_t length);',
    { functions: { hao_fill_bytes: { buffers: { data: { length: 'length', element: 'u8', direction: 'sideways' } } } } }],
];
for (const [declarations, options] of cases) {
  try { const library = cdecl(path, declarations, options); library.close(); console.log('accepted'); }
  catch { console.log('rejected'); }
}
const valid = cdecl(path, 'void hao_fill_bytes(uint8_t *data, size_t length);', {
  functions: { hao_fill_bytes: { buffers: { data: { length: 'length', element: 'u8', direction: 'out' } } } },
});
const bytes = new Uint8Array(3);
valid.hao_fill_bytes(bytes);
console.log(Array.from(bytes).join(','));
valid.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-policy-validation.ts")" = "$(printf 'rejected\nrejected\nrejected\nrejected\nrejected\nrejected\n1,2,3')"
cat > "$fixture_dir/ffi-u64.ts" <<'EOF'
import { dlopen } from 'std:ffi';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = dlopen(`${path}/libhao_search_fixture.dylib`, {
  hao_high_bit: { args: ['u64'], returns: 'u64' },
  hao_echo_u64: { args: ['u64'], returns: 'u64' },
  hao_u64_max: { args: [], returns: 'u64' },
  hao_u64_mid: { args: [], returns: 'u64' },
  hao_long_string: { args: [], returns: 'cstring' },
});
console.log(library.hao_high_bit(9223372036854775808n));
console.log(library.hao_echo_u64(18446744073709551615n));
console.log(library.hao_u64_max(), library.hao_u64_mid());
console.log(library.hao_long_string().length);
library.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-u64.ts")" = "$(printf '1\n18446744073709552000\n18446744073709552000 9007199254740992\n1048593')"
cat > "$fixture_dir/ffi-widths.ts" <<'EOF'
import { dlopen } from 'std:ffi';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = dlopen(`${path}/libhao_search_fixture.dylib`, {
  hao_echo_i8: { args: ['i8'], returns: 'i8' },
  hao_echo_u8: { args: ['u8'], returns: 'u8' },
  hao_echo_f32: { args: ['f32'], returns: 'f32' },
});
console.log(library.hao_echo_i8(130), library.hao_echo_i8(-129), library.hao_echo_u8(258));
console.log(library.hao_echo_f32(1.1));
try { library.hao_echo_u8(-1); } catch (error) { console.log(error.name, error.message); }
library.close();
EOF
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-widths.ts")" = "$(printf '%s\n%s\n%s' '-126 127 2' '1.100000023841858' 'TypeError FFI: invalid argument value')"
cat > "$fixture_dir/ffi-search.ts" <<'EOF'
import { cdecl } from 'std:ffi/c';
import { getEnv } from 'std:process';
const path = getEnv('HAO_FFI_TEST_PATH');
const library = cdecl('hao_search_fixture', `/* status # ignored */ int32_t hao_search_value(void); // first call
int32_t hao_make_handle(void **out); int32_t hao_fail_handle(void **out);
int32_t hao_fail_with_code(int32_t code); const char *hao_error_message(int32_t code);`, {
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
const fallback = cdecl('hao_search_fixture', 'int32_t hao_search_value(void);', {
  search: { strategy: 'system-first', paths: [path] },
});
console.log(fallback.hao_search_value());
fallback.close();
const boxes = cdecl('hao_search_fixture',
  'typedef struct HaoBox HaoBox; HaoBox *hao_box_open(void); int32_t hao_box_open_out(HaoBox **out); int32_t hao_box_value(HaoBox *box); void hao_box_close(HaoBox *box);', {
    search: { strategy: 'relative-first', paths: [path] },
    handles: { HaoBox: { close: 'hao_box_close' } },
    functions: {
      hao_box_open: { returns: { kind: 'handle', type: 'HaoBox' } },
      hao_box_open_out: { returns: { out: 'out' } },
    },
  });
const box = boxes.hao_box_open();
console.log(boxes.hao_box_value(box));
box.close();
const outBox = boxes.hao_box_open_out();
console.log(boxes.hao_box_value(outBox));
outBox.close();
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
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-search.ts")" = "$(printf '29\n4660\nC: native call failed\nstatus 7\n29\n37\n37\n4 12\n7 3.75\n2 11 4 9\nopenNative: unsupported or invalid C declarations: SyntaxError')"
mv "$fixture_dir/libhao_search_fixture.dylib" "$fixture_dir/libhao_search_fixture.so"
test "$(HAO_FFI_TEST_PATH="$fixture_dir" "$runtime" "$fixture_dir/ffi-search.ts")" = "$(printf '29\n4660\nC: native call failed\nstatus 7\n29\n37\n37\n4 12\n7 3.75\n2 11 4 9\nopenNative: unsupported or invalid C declarations: SyntaxError')"

mkdir -p "$fixture_dir/app/node_modules/demo" "$fixture_dir/app/node_modules/@scope/tool" "$fixture_dir/vendor/external"
mkdir -p "$fixture_dir/symlink-app" "$fixture_dir/symlink-target"
printf "import { value } from './link.ts'; console.log(value);\n" > "$fixture_dir/symlink-app/main.ts"
printf "import { value } from './local.ts'; export { value };\n" > "$fixture_dir/symlink-target/dep.ts"
printf "export const value = 'app';\n" > "$fixture_dir/symlink-app/local.ts"
printf "export const value = 'target';\n" > "$fixture_dir/symlink-target/local.ts"
ln -s "$fixture_dir/symlink-target/dep.ts" "$fixture_dir/symlink-app/link.ts"
test "$("$runtime" "$fixture_dir/symlink-app/main.ts")" = 'app'
mkdir -p "$fixture_dir/symlink-app/node_modules/demo-symlink"
printf '{"exports":"./link.ts"}\n' > "$fixture_dir/symlink-app/node_modules/demo-symlink/package.json"
printf "export const value = 'package';\n" > "$fixture_dir/symlink-app/node_modules/demo-symlink/local.ts"
ln -s "$fixture_dir/symlink-target/dep.ts" "$fixture_dir/symlink-app/node_modules/demo-symlink/link.ts"
printf "import { value } from 'demo-symlink'; console.log(value);\n" > "$fixture_dir/symlink-app/package-main.ts"
test "$("$runtime" "$fixture_dir/symlink-app/package-main.ts")" = 'package'
printf '{"type":"module","exports":{".":{"import":"./index.ts"},"./extra":"./extra.mjs"}}\n' > "$fixture_dir/app/node_modules/demo/package.json"
printf 'export const value: number = 42;\n' > "$fixture_dir/app/node_modules/demo/index.ts"
printf 'export const extra = 3;\n' > "$fixture_dir/app/node_modules/demo/extra.mjs"
printf '{"type":"module","main":"./index.js"}\n' > "$fixture_dir/app/node_modules/@scope/tool/package.json"
printf 'export const scoped = 7;\n' > "$fixture_dir/app/node_modules/@scope/tool/index.js"
printf 'import { value } from "demo"; import { extra } from "demo/extra"; import { scoped } from "@scope/tool"; console.log(value, extra, scoped);\n' > "$fixture_dir/app/packages.ts"
test "$("$runtime" "$fixture_dir/app/packages.ts")" = '42 3 7'
mkdir -p "$fixture_dir/app/node_modules/dotted"
printf '{"exports":"./foo..bar.mjs"}\n' > "$fixture_dir/app/node_modules/dotted/package.json"
printf 'export const dotted = 23;\n' > "$fixture_dir/app/node_modules/dotted/foo..bar.mjs"
printf 'import { dotted } from "dotted"; console.log(dotted);\n' > "$fixture_dir/app/dotted.ts"
test "$("$runtime" "$fixture_dir/app/dotted.ts")" = '23'
mkdir -p "$fixture_dir/app/node_modules/shadowed"
printf '{"exports":"./entry"}\n' > "$fixture_dir/app/node_modules/shadowed/package.json"
printf 'plain file\n' > "$fixture_dir/app/node_modules/shadowed/entry"
printf 'export const value = 99;\n' > "$fixture_dir/app/node_modules/shadowed/entry.ts"
printf 'import { value } from "shadowed"; console.log(value);\n' > "$fixture_dir/app/shadowed.ts"
if "$runtime" "$fixture_dir/app/shadowed.ts" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected the first existing package entry to block later extensions' >&2
    exit 1
fi
grep -q 'Cannot resolve package: shadowed' "$fixture_dir/stderr"
mkdir -p "$fixture_dir/app/node_modules/colon/child"
printf '{"exports":{"./native":"./wrong.mjs"}}\n' > "$fixture_dir/app/node_modules/colon/package.json"
printf 'export const selected = "wrong";\n' > "$fixture_dir/app/node_modules/colon/wrong.mjs"
printf '{"exports":{"./native":"./native.mjs"}}\n' > "$fixture_dir/app/node_modules/colon/child/package.json"
printf 'export const selected = "child";\n' > "$fixture_dir/app/node_modules/colon/child/native.mjs"
printf 'import { selected } from "colon/child:native"; console.log(selected);\n' > "$fixture_dir/app/colon.ts"
test "$("$runtime" "$fixture_dir/app/colon.ts")" = 'child'
mkdir -p "$fixture_dir/app/node_modules/plain"
printf '{"type":"module","main":"index.js"}\n' > "$fixture_dir/app/node_modules/plain/package.json"
printf 'export const selected = "plain";\n' > "$fixture_dir/app/node_modules/plain/index.js"
printf 'import { selected } from "plain"; console.log(selected);\n' > "$fixture_dir/app/plain.ts"
test "$("$runtime" "$fixture_dir/app/plain.ts")" = 'plain'
printf '{"exports":"./index.mjs"}\n' > "$fixture_dir/vendor/external/package.json"
printf 'export const value = 11;\n' > "$fixture_dir/vendor/external/index.mjs"
printf 'import { value } from "external"; console.log("external", value);\n' > "$fixture_dir/app/external.ts"
test "$(RUNTIME_PACKAGE_PATH="$fixture_dir/vendor" "$runtime" "$fixture_dir/app/external.ts")" = 'external 11'
test "$(RUNTIME_PACKAGE_PATH="  $fixture_dir/vendor  " "$runtime" "$fixture_dir/app/external.ts")" = 'external 11'
mkdir -p "$fixture_dir/vendor/priority" "$fixture_dir/app/node_modules/priority"
printf '{"exports":{".":"./index.mjs"}}\n' > "$fixture_dir/vendor/priority/package.json"
printf 'export const source = "vendor";\n' > "$fixture_dir/vendor/priority/index.mjs"
printf '{"exports":{"./extra":"./extra.mjs"}}\n' > "$fixture_dir/app/node_modules/priority/package.json"
printf 'export const source = "local";\n' > "$fixture_dir/app/node_modules/priority/extra.mjs"
printf 'import { source } from "priority/extra"; console.log(source);\n' > "$fixture_dir/app/priority.ts"
test "$("$runtime" "$fixture_dir/app/priority.ts")" = 'local'
if RUNTIME_PACKAGE_PATH="$fixture_dir/vendor" "$runtime" "$fixture_dir/app/priority.ts" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected the first package to block an unexported subpath' >&2
    exit 1
fi
grep -q 'Cannot resolve package: priority/extra' "$fixture_dir/stderr"
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
const coerced = await run({ cmd: 'sh', args: ['-c', 'printf \"%s,%s,%s\" \"$1\" \"$2\" \"$3\"', 'sh', 42, true, null] });
console.log('coerced', coerced.stdout);
try { await run({ cmd: 'sh', args: ['-c', 'exit 9'] }); } catch (error) { console.log('checked', error.exitCode); }
try { await run({ cmd: 'sh', args: ['-c', 'printf 12345'], maxOutputBytes: 3 }); } catch (error) { console.log('limited', error.message); }
EOF
process_actual=$(HAO_CYNA_TEST=works "$runtime" "$fixture_dir/process.ts")
process_expected=$(printf 'env works\nrun hello warn 0\njson 42\nunchecked 7\nsignaled null 15\ncwd /private/tmp\nlargeLimit ok\ncoerced 42,true,null\nchecked 9\nlimited process.run failed')
test "$process_actual" = "$process_expected"
cat > "$fixture_dir/process-nul.ts" <<'EOF'
import { run } from 'std:process';
const result = await run({ cmd: 'sh', args: ['-c', "printf 'a\\000b'; printf 'c\\000d' >&2"], check: false });
console.log(result.stdout.length, result.stderr.length, result.stdout, result.stderr);
EOF
test "$("$runtime" "$fixture_dir/process-nul.ts")" = '1 1 a c'
cat > "$fixture_dir/process-input-nul.ts" <<'EOF'
import { run } from 'std:process';
const result = await run({ cmd: 'sh\0other', args: ['-c', 'printf ok\0bad'], cwd: '/tmp\0missing' });
console.log(result.stdout, result.exitCode);
EOF
test "$("$runtime" "$fixture_dir/process-input-nul.ts")" = 'ok 0'
cat > "$fixture_dir/process-errors.ts" <<'EOF'
import { runNative, getEnvNative } from 'std:process/native';
for (const invoke of [() => getEnvNative(), () => runNative(null), () => runNative({}),
  () => runNative({ cmd: 'sh', args: 3 }), () => runNative({ cmd: 'sh', cwd: 3 }),
  () => runNative({ cmd: 'sh', maxOutputBytes: 0 }),
  () => runNative({ cmd: 'sh', args: ['-c', 'printf 12345'], maxOutputBytes: 3 }),
  () => runNative({ cmd: '' }), () => runNative({ cmd: 'sh', args: ['-c', 'pwd'], cwd: '' })]) {
  try { invoke(); } catch (error) { console.log(error.name, error.message); }
}
EOF
test "$("$runtime" "$fixture_dir/process-errors.ts")" = "$(printf 'TypeError getEnvNative expects a variable name\nTypeError process.run requires an options object\nTypeError process.run requires options.cmd\nTypeError process.run args must be a string array\nInternalError process.run failed\nTypeError process.run maxOutputBytes must be positive\nInternalError process.run failed\nInternalError process.run failed\nInternalError process.run failed')"
cat > "$fixture_dir/process-large-env.ts" <<'EOF'
import { getEnvNative } from 'std:process/native';
console.log(getEnvNative('HAO_BIG_ENV')?.length);
EOF
python3 - "$runtime" "$fixture_dir/process-large-env.ts" <<'PY'
import os, subprocess, sys
result = subprocess.run(sys.argv[1:], env={**os.environ, 'HAO_BIG_ENV': 'x' * 70000},
    capture_output=True, text=True, check=True)
assert result.stdout.strip() == '70000', result.stdout
PY

printf 'console.log("before"); const cancelled = setTimeout(() => console.log("cancelled"), 1); clearTimeout(cancelled); setTimeout(() => { console.log("after"); Promise.resolve().then(() => console.log("microtask")); }, 1);\n' > "$fixture_dir/timer.ts"
timer_actual=$("$runtime" "$fixture_dir/timer.ts")
timer_expected=$(printf 'before\nafter\nmicrotask')
test "$timer_actual" = "$timer_expected"

printf 'setTimeout(() => { console.log("first"); Promise.resolve().then(() => console.log("job")); }, 1); setTimeout(() => console.log("second"), 10);\n' > "$fixture_dir/timer-turns.ts"
timer_turns_actual=$("$runtime" "$fixture_dir/timer-turns.ts")
timer_turns_expected=$(printf 'first\njob\nsecond')
test "$timer_turns_actual" = "$timer_turns_expected"

cat > "$fixture_dir/timer-error.ts" <<'EOF'
setTimeout(() => { throw Error('timer exploded'); }, 0);
setTimeout(() => { console.log('later timer'); }, 20);
EOF
python3 - "$runtime" "$fixture_dir/timer-error.ts" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert result.returncode == 1 and result.stdout == '', result
assert result.stderr == f'timer exploded\n    at <anonymous> ({sys.argv[2]}:2:8)\n\n', result
PY
cat > "$fixture_dir/timer-rejection.ts" <<'EOF'
setTimeout(() => { Promise.reject(Error('timer rejected')); }, 0);
setTimeout(() => { console.log('later timer'); }, 20);
EOF
python3 - "$runtime" "$fixture_dir/timer-rejection.ts" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1], sys.argv[2]], capture_output=True, text=True)
assert result.returncode == 1 and result.stdout == '', result
assert result.stderr == f'timer rejected\n    at <anonymous> ({sys.argv[2]}:2:17)\n\n', result
PY

cat > "$fixture_dir/timer-nested.ts" <<'EOF'
const events: string[] = [];
const cancelled = setTimeout(() => events.push('cancelled'), 1);
clearTimeout(cancelled);
setTimeout(() => {
  events.push('first');
  Promise.resolve().then(() => events.push('job'));
  setTimeout(() => {
    events.push('nested');
    console.log(JSON.stringify(events));
  }, 1);
}, 1);
EOF
test "$("$runtime" "$fixture_dir/timer-nested.ts")" = '["first","job","nested"]'

cat > "$fixture_dir/timer-arguments.ts" <<'EOF'
import { startTraceNative } from 'std:telemetry/native';
console.log(typeof startTraceNative);
setTimeout((value: unknown) => console.log(value === undefined ? 'none' : String(value)), 1, 42);
EOF
test "$("$runtime" "$fixture_dir/timer-arguments.ts")" = "$(printf 'function\nnone')"

printf 'setTimeout(() => { throw new Error("timer failed"); }, 1);\n' > "$fixture_dir/timer-failure.ts"
if "$runtime" "$fixture_dir/timer-failure.ts" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected timer callback to exit with an error' >&2
    exit 1
fi
grep -q '^timer failed$' "$fixture_dir/stderr"

printf 'throw new Error("expected failure");\n' > "$fixture_dir/failure.js"
if "$runtime" "$fixture_dir/failure.js" > "$fixture_dir/stdout" 2> "$fixture_dir/stderr"; then
    echo 'expected failure script to exit with an error' >&2
    exit 1
fi
grep -q '^expected failure$' "$fixture_dir/stderr"
