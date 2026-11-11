#!/usr/bin/env python3
"""Exercise temporary typed array ownership during raw Cyna FFI calls."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

PROBE = '''import { openNative, callNative, closeNative } from 'std:ffi/native';
const handle = openNative('c', { memcmp: { args: ['ptr', 'ptr', 'u64'], returns: 'i32' } });
const stable = new Uint8Array([1, 2, 3, 4]);
let checksum = 0;
for (let iteration = 0; iteration < 100; iteration++) {
  const args = new Array(3);
  Object.defineProperty(args, '0', { get() { return new Uint8Array([1, 2, 3, 4]); } });
  args[1] = stable;
  Object.defineProperty(args, '2', { get() {
    for (let i = 0; i < 500; i++) new Uint8Array(1024);
    return 4;
  } });
  checksum += callNative(handle, 'memcmp', args);
}
console.log(checksum);
closeNative(handle);
'''


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: ffi_pointer_lifetime.py CYNA_HAO', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='hao-ffi-lifetime-') as directory:
        source = Path(directory) / 'probe.ts'
        source.write_text(PROBE)
        result = subprocess.run((str(Path(sys.argv[1]).resolve()), str(source)),
                                env={**os.environ, 'RUNTIME_GC_THRESHOLD': '1'},
                                capture_output=True, timeout=20)
    if result.returncode != 0 or result.stdout != b'0\n' or result.stderr:
        print(repr((result.returncode, result.stdout, result.stderr)), file=sys.stderr)
        return 1
    print('FFI temporary typed array survived 100 native calls with GC pressure')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
