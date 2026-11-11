#!/usr/bin/env python3
"""Compare legacy and Cyna unsigned FFI argument conversion."""

from pathlib import Path
import subprocess
import sys
import tempfile


SOURCE = '''#include <stdint.h>
uint64_t hao_echo_u64(uint64_t value) { return value; }
uintptr_t hao_pointer_bits(void *value) { return (uintptr_t)value; }
'''
SCRIPT = '''import { dlopen } from 'std:ffi';
const library = dlopen('./libhao_unsigned.dylib', {
  hao_echo_u64: { args: ['u64'], returns: 'u64' },
  hao_pointer_bits: { args: ['ptr'], returns: 'u64' },
});
const values = [
  '0', '42', '18446744073709551615', '18446744073709551615n',
  '18446744073709551615nn', '18446744073709551616',
  '', 'n', 'nn', '-1', '+1', ' 1', '1 ', '1.5', '1x',
  '00042', '00000000000000000000000000000000042',
  null, undefined, 0, 42, 9007199254740991, 18446744073709551615n,
];
for (const name of ['hao_echo_u64', 'hao_pointer_bits']) {
  for (let index = 0; index < values.length; index++) {
    if (name === 'hao_echo_u64' && index === 9) continue;
    try { console.log(name, index, library[name](values[index])); }
    catch (error) { console.log(name, index, error.name, error.message); }
  }
}
library.close();
'''


def run(binary: Path, directory: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((str(binary), str(directory / 'probe.ts')),
                            cwd=directory, capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy, port = (Path(arg).resolve() for arg in sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix='hao-ffi-unsigned-') as temporary:
        directory = Path(temporary)
        (directory / 'fixture.c').write_text(SOURCE)
        (directory / 'probe.ts').write_text(SCRIPT)
        subprocess.run(('cc', '-dynamiclib', 'fixture.c', '-o',
                        'libhao_unsigned.dylib'), cwd=directory, check=True)
        expected = run(legacy, directory)
        actual = run(port, directory)
        assert actual == expected, (expected, actual)
    print('FFI unsigned arguments: 45 Zig/Cyna outcomes matched')


if __name__ == '__main__':
    main()
