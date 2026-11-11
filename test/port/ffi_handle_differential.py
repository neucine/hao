#!/usr/bin/env python3
"""Compare FFI library handle conversion, closure, and reuse with Zig."""
from pathlib import Path
import subprocess
import sys
import tempfile

PROBE = '''import { openNative, closeNative, callNative } from 'std:ffi/native';
const h1 = openNative('m', { sqrt: { args: ['f64'], returns: 'f64' } });
const h2 = openNative('m', { sqrt: { args: ['f64'], returns: 'f64' } });
console.log('ids', h1, h2);
for (const [label, h] of [['h1', h1], ['h2', h2], ['zero', 0],
  ['negative', -1], ['unknown', 999999], ['null', null],
  ['undefined', undefined], ['text', '1'],
  ['object', { valueOf() { return h2; } }]]) {
  try { console.log('call', label, callNative(h, 'sqrt', [4])); }
  catch (error) { console.log('call', label, error.name, error.message); }
  try { console.log('close', label, closeNative(h)); }
  catch (error) { console.log('close', label, error.name, error.message); }
}
for (const [label, h] of [['h1', h1], ['h2', h2]]) {
  try { console.log('again', label, callNative(h, 'sqrt', [4])); }
  catch (error) { console.log('again', label, error.name, error.message); }
  try { console.log('close again', label, closeNative(h)); }
  catch (error) { console.log('close again', label, error.name, error.message); }
}
'''


def run(binary: Path, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((str(binary), str(script)), capture_output=True,
                            timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: ffi_handle_differential.py LEGACY_HAO CYNA_HAO', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='hao-ffi-handles-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text(PROBE)
        legacy, cyna = (run(Path(arg).resolve(), script) for arg in sys.argv[1:])
    if legacy != cyna:
        print('legacy:', repr(legacy), file=sys.stderr)
        print('cyna:', repr(cyna), file=sys.stderr)
        return 1
    assert legacy[0] == 0 and len(legacy[1].splitlines()) == 23, legacy
    print('FFI handle lifecycle matched legacy: 23 outcomes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
