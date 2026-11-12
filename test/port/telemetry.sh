#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime=${1:-"$repo_root/build/hao-cyna"}
modules=${2:-"$repo_root/build/modules"}
embed_library=${3:-"$repo_root/build/libhao-cyna-embed.a"}
cyna_bin=${4:-"${HAO_CYNA_SOURCE:-$repo_root/.deps/cyna-source}/zig-out/bin/cyna"}
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT HUP INT TERM

cyna_dir=$(CDPATH= cd -- "$(dirname -- "$cyna_bin")/.." && pwd -P)
if [ -f "$cyna_dir/lib/libcyna_std.a" ]; then
    cyna_lib="$cyna_dir/lib"
else
    cyna_lib="$cyna_dir/targets/aarch64-apple-darwin/lib"
fi

clang -I "$repo_root/include" -I "$repo_root/.deps/install/include" \
    "$repo_root/test/port/telemetry_runtime.c" "$embed_library" \
    -L "$cyna_lib" -lcyna_std -lcyna \
    -L "$repo_root/.deps/install/lib" -lquickjs -luv \
    -L "$repo_root/libs/transpiler/target/release" -lhao_transpiler \
    -L /opt/homebrew/lib -lcurl -lffi -lzmq -lcrypto \
    -o "$fixture_dir/telemetry-runtime"
"$fixture_dir/telemetry-runtime" "$modules"

cat > "$fixture_dir/error-flow.ts" <<'EOF'
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';

trace('sync-root', () => {
  try { trace('sync-fail', () => { throw Error('sync'); }); } catch {}
  trace('sync-after', () => {});
});
await trace('async-root', async () => {
  try { await trace('async-fail', async () => { throw Error('async'); }); } catch {}
  trace('async-after', () => {});
});

const records = snapshotTraceRecordsNative().records;
const starts = records.filter(record => record.kind === 'span_start');
const ends = records.filter(record => record.kind === 'span_end');
const parent = (name: string) => starts.find(record => record.name === name)!;

console.log(ends.find(record => record.name === 'sync-fail')?.status,
  parent('sync-fail').parent_span_id === parent('sync-root').span_id);
console.log(ends.find(record => record.name === 'async-fail')?.status,
  parent('async-fail').parent_span_id === parent('async-root').span_id);
console.log(parent('sync-after').parent_span_id === parent('sync-root').span_id,
  parent('async-after').parent_span_id === parent('async-root').span_id);
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/error-flow.ts")" = "$(printf 'err true\nerr true\ntrue true')"

cat > "$fixture_dir/filters.ts" <<'EOF'
import { startRootTraceNative, addTraceEventNative, endTraceNative,
  snapshotTraceRecordsNative } from 'std:telemetry/native';

const first = startRootTraceNative('fixture one', { route: '/one' });
const firstStart = snapshotTraceRecordsNative().records.at(-1)!;
addTraceEventNative(first, 'fixture event', { count: 2 });
endTraceNative(first, 'err');
const second = startRootTraceNative('fixture two');
endTraceNative(second, 'ok');

const all = snapshotTraceRecordsNative(0, 100).records;
const name = snapshotTraceRecordsNative(0, 100, { name: 'fixture one' }).records;
const span = snapshotTraceRecordsNative(0, 100, { span_id: firstStart.span_id }).records;
const status = snapshotTraceRecordsNative(0, 100, { status: 'err' }).records;
const since = snapshotTraceRecordsNative(
  0, 100, { since_ns: firstStart.timestamp_ns + 1 }).records;
const missing = snapshotTraceRecordsNative(0, 100, { name: 'absent' });
const combined = snapshotTraceRecordsNative(
  0, 100, { source_kind: 'javascript', name: 'fixture event' }).records;
const firstPage = snapshotTraceRecordsNative(0, 2, { source_kind: 'javascript' });
const secondPage = snapshotTraceRecordsNative(
  firstPage.next_cursor, 2, { source_kind: 'javascript' });
const thirdPage = snapshotTraceRecordsNative(
  secondPage.next_cursor, 2, { source_kind: 'javascript' });

console.log(all.length, name.length, span.length, status.length, since.length);
console.log(missing.records.length, missing.next_cursor, all.at(-1)!.sequence,
  combined.length);
console.log(firstPage.records.length, firstPage.records[0].sequence, firstPage.next_cursor);
console.log(secondPage.records.length, secondPage.records[0].sequence, secondPage.next_cursor);
console.log(thirdPage.records.length, thirdPage.records[0].sequence, thirdPage.next_cursor);
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/filters.ts")" = "$(printf '5 2 3 1 4\n0 5 5 1\n2 1 2\n2 3 4\n1 5 5')"

mkdir -p "$fixture_dir/node_modules/trace"
clang -dynamiclib -I "$repo_root/include" "$repo_root/test/port/telemetry_addon.c" \
    -o "$fixture_dir/node_modules/trace/native.dylib"
cat > "$fixture_dir/node_modules/trace/package.json" <<'EOF'
{"type":"module","exports":{"./native":"./native.dylib"}}
EOF
cat > "$fixture_dir/addon-contract.ts" <<'EOF'
import native from 'trace:native';
import { trace } from 'std:telemetry';
import { snapshotTraceRecordsNative } from 'std:telemetry/native';

native.probeFailures();
trace('addon-parent', () => native.emit());
native.emitRoot();

const records = snapshotTraceRecordsNative().records;
const parent = records.find(record => record.kind === 'span_start' && record.name === 'addon-parent')!;
const child = records.find(record => record.kind === 'span_start' && record.name === 'addon-work')!;
const root = records.find(record => record.kind === 'span_start' && record.name === 'fixture root')!;
const event = records.find(record => record.name === 'fixture received')!;
const addon = snapshotTraceRecordsNative(
  0, 100, { source_kind: 'addon', source: 'fixture source' }).records;

console.log(child.parent_span_id === parent.span_id, child.trace_id === parent.trace_id);
console.log(root.parent_span_id === '0000000000000000', root.source);
console.log(event.attributes.flag, event.attributes.count, event.attributes.ratio,
  event.attributes.label, addon.length);
EOF
test "$(RUNTIME_TELEMETRY_CONSOLE=1 "$runtime" "$fixture_dir/addon-contract.ts")" = "$(printf 'true true\ntrue fixture source\ntrue 3 1.5 fixture 3')"

mkdir -p "$fixture_dir/node_modules/bad"
clang -dynamiclib -I "$repo_root/include" "$repo_root/test/port/addon_abi_mismatch.c" \
    -o "$fixture_dir/node_modules/bad/native.dylib"
cat > "$fixture_dir/node_modules/bad/package.json" <<'EOF'
{"type":"module","exports":{"./native":"./native.dylib"}}
EOF
cat > "$fixture_dir/addon-mismatch.ts" <<'EOF'
import native from 'bad:native';
console.log(native);
EOF
if "$runtime" "$fixture_dir/addon-mismatch.ts" > "$fixture_dir/mismatch.stdout" 2> "$fixture_dir/mismatch.stderr"; then
    echo "expected addon ABI mismatch to fail" >&2
    exit 1
fi
grep -q 'Cannot load native addon' "$fixture_dir/mismatch.stderr"

cat > "$fixture_dir/console-addon.ts" <<'EOF'
import native from 'trace:native';
native.emitRoot();
setTimeout(() => {}, 1500);
EOF
python3 - "$runtime" "$fixture_dir/console-addon.ts" <<'PY'
import json, os, re, subprocess, sys, urllib.request

process = subprocess.Popen(
    [sys.argv[1], sys.argv[2]],
    env=dict(os.environ, RUNTIME_TELEMETRY_CONSOLE='1',
             RUNTIME_TELEMETRY_CONSOLE_PORT='0'),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    line = process.stderr.readline()
    match = re.search(r'http://127\.0\.0\.1:(\d+)/', line)
    assert match, line
    base = 'http://127.0.0.1:' + match.group(1)

    def get(path):
        with urllib.request.urlopen(base + path, timeout=2) as response:
            return json.loads(response.read())

    all_records = get('/api/traces?limit=20')
    root = next(record for record in all_records['records']
                if record['kind'] == 'span_start' and record['name'] == 'fixture root')

    source = get('/api/traces?source=fixture%20source')
    assert [record['kind'] for record in source['records']] == [
        'span_start', 'event', 'span_end'
    ]
    by_span = get('/api/traces?span_id=' + root['span_id'])
    assert [record['kind'] for record in by_span['records']] == [
        'span_start', 'event', 'span_end'
    ]
    ok = get(
        '/api/traces?source_kind=addon&source=fixture%20source'
        '&name=fixture%20root&status=ok'
    )
    assert len(ok['records']) == 1 and ok['records'][0]['kind'] == 'span_end'
    absent = get('/api/traces?name=absent')
    assert absent['records'] == []
    assert absent['next_cursor'] == all_records['next_cursor']
    future = get('/api/traces?since_ns=1e30')
    assert future['records'] == []
    assert process.wait(timeout=5) == 0
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
PY
