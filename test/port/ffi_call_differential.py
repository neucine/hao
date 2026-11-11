#!/usr/bin/env python3
"""Compare Zig and Cyna validation order for legacy FFI calls."""

from pathlib import Path
import subprocess
import sys
import tempfile


PROBE = '''import { openNative, callNative, closeNative } from 'std:ffi/native';
const handle = openNative('m', { sqrt: { args: ['f64'], returns: 'f64' } });
const cases = [
  [0, 'sqrt', [4]], [null, 'sqrt', [4]], ['x', 'sqrt', [4]],
  [handle, null, [4]], [handle, 0, [4]], [handle, Symbol('x'), [4]],
  [handle, { toString() { throw Error('name boom'); } }, [4]],
  [handle, 'missing', [4]], [handle, 'sqrt', null], [handle, 'sqrt', {}],
  [handle, 'sqrt', new Proxy([4], {})], [handle, 'sqrt', []],
  [handle, 'sqrt', [4, 5]], [handle, 'sqrt', [Symbol('x')]],
];
for (let index = 0; index < cases.length; index++) {
  try { console.log(index, JSON.stringify(callNative(...cases[index]))); }
  catch (error) { console.log(index, error.name, error.message); }
}
closeNative(handle);
'''


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-ffi-call-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text(PROBE)
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print('FFI calls: 14 Zig/Cyna validation outcomes matched')


if __name__ == '__main__':
    main()
