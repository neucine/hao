#!/usr/bin/env python3
"""Compare public filesystem conversion behavior in isolated directories."""
from pathlib import Path
import subprocess
import sys
import tempfile

PATH_SOURCE = r'''import { existsSync, readFileSync, writeFileSync, statSync } from 'std:fs';
const values = [undefined, null, true, false, 0, 1, -1, NaN, Infinity, '', '.',
  './missing', [], [1], {}, { toString() { return 'missing' } },
  { toString() { throw Error('bad path') } }, Symbol('x'), BigInt(42),
  new String('missing'), { valueOf() { return 'missing' } }];
for (const [name, fn] of Object.entries({ existsSync, readFileSync, statSync, writeFileSync })) {
  for (let i = 0; i < values.length; i++) {
    try {
      const result = name === 'writeFileSync' ? fn(values[i], 'x') : fn(values[i]);
      console.log(name, i, JSON.stringify(result));
    } catch (error) { console.log(name, i, error.name, error.message); }
  }
}
'''
DATA_SOURCE = r'''import { writeFileSync, readFileSync, statSync } from 'std:fs';
const values = [undefined, null, true, false, 0, 1, -1, NaN, Infinity, '', 'x',
  'é', '😀', 'a\0b', [], [1], {}, { toString() { return 'text' } },
  { toString() { throw Error('bad data') } }, Symbol('x'), BigInt(42),
  new String('x'), { valueOf() { return 'value' } }];
for (let i = 0; i < values.length; i++) {
  try {
    const path = 'data-' + i;
    writeFileSync(path, values[i]);
    console.log(i, JSON.stringify(readFileSync(path)), statSync(path).size);
  } catch (error) { console.log(i, error.name, error.message); }
}
'''


def run(binary: str, root: Path, source: str) -> tuple[int, bytes, bytes]:
    root.mkdir()
    script = root / 'probe.ts'
    script.write_text(source)
    result = subprocess.run((binary, str(script)), cwd=root, capture_output=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-fs-diff-') as directory:
        root = Path(directory)
        for index, source in enumerate((PATH_SOURCE, DATA_SOURCE)):
            expected = run(legacy, root / f'legacy-{index}', source)
            actual = run(cyna, root / f'cyna-{index}', source)
            assert actual == expected, (index, expected, actual)
    print('filesystem differential: 84 path operations and 23 data values matched')


if __name__ == '__main__':
    main()
