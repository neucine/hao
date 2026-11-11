#!/usr/bin/env python3
"""Compare process option conversion and independent output limits."""
from pathlib import Path
import subprocess
import sys
import tempfile

COMMANDS = r'''import { run } from 'std:process';
const values = [undefined, null, true, false, 0, 1, -1, NaN, Infinity, '',
  'echo', '/bin/echo', 'missing-command', [], [1], {},
  { toString() { return '/bin/echo' } },
  { toString() { throw Error('bad cmd') } }, Symbol('x'), BigInt(42),
  new String('/bin/echo'), { valueOf() { return '/bin/echo' } }];
for (let i = 0; i < values.length; i++) {
  try {
    const result = await run({ cmd: values[i], args: ['ok'], check: false });
    console.log(i, JSON.stringify(result.stdout), JSON.stringify(result.stderr),
      result.exitCode, result.signal);
  } catch (error) { console.log(i, error.name, error.message); }
}
'''
ARGS = r'''import { run } from 'std:process';
const values = [undefined, null, true, false, 0, 1, -1, NaN, Infinity, '',
  'x', 'é', '😀', 'a\0b', [], [1], {},
  { toString() { return 'text' } },
  { toString() { throw Error('bad arg') } }, Symbol('x'), BigInt(42),
  new String('x'), { valueOf() { return 'value' } }];
for (let i = 0; i < values.length; i++) {
  try {
    const result = await run({ cmd: '/bin/echo', args: [values[i]], check: false });
    console.log(i, JSON.stringify(result.stdout), JSON.stringify(result.stderr),
      result.exitCode, result.signal);
  } catch (error) { console.log(i, error.name, error.message); }
}
'''
ARRAYS = r'''import { run } from 'std:process';
const arrays = [[], [,,], Array(3), ['x',, 'z'],
  Object.assign(['x'], { length: 4 }),
  new Proxy(['x'], { get(target, key, receiver) {
    if (key === '0') throw Error('arg get');
    return Reflect.get(target, key, receiver);
  } }),
  new Proxy(['x'], { get(target, key, receiver) {
    if (key === 'length') throw Error('len get');
    return Reflect.get(target, key, receiver);
  } }),
  { length: 1, 0: 'x' }, null, undefined, 'x'];
for (let i = 0; i < arrays.length; i++) {
  try {
    const result = await run({ cmd: '/bin/echo', args: arrays[i], check: false });
    console.log(i, JSON.stringify(result.stdout), result.exitCode);
  } catch (error) { console.log(i, error.name, error.message); }
}
'''
LIMITS = r'''import { run } from 'std:process';
for (const limit of [1, 4, 8, 9, 10, 15, 16, 17, 32]) {
  try {
    const result = await run({ cmd: '/bin/sh',
      args: ['-c', 'printf 12345678; printf abcdefgh >&2'],
      maxOutputBytes: limit, check: false });
    console.log(limit, JSON.stringify(result.stdout),
      JSON.stringify(result.stderr), result.exitCode);
  } catch (error) { console.log(limit, error.name, error.message); }
}
'''


def run(binary: str, root: Path, source: str) -> tuple[int, bytes, bytes]:
    root.mkdir()
    script = root / 'probe.ts'
    script.write_text(source)
    result = subprocess.run((binary, str(script)), cwd=root, capture_output=True, timeout=15)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-process-diff-') as directory:
        root = Path(directory)
        for index, source in enumerate((COMMANDS, ARGS, ARRAYS, LIMITS)):
            expected = run(legacy, root / f'legacy-{index}', source)
            actual = run(cyna, root / f'cyna-{index}', source)
            assert actual == expected, (index, expected, actual)
    print('process differential: 21 commands, 34 argument forms, 9 output limits matched')


if __name__ == '__main__':
    main()
