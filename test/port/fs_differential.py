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
PATH_KIND_SOURCE = r'''import { existsSync, readFileSync, statSync, writeFileSync } from 'std:fs';
const paths = ['file', 'dir', 'link-file', 'link-dir', 'broken-link', 'missing',
  'file\0suffix', 'dir/file', 'file/child'];
for (const [index, path] of paths.entries()) {
  for (const [name, operation] of Object.entries({
    existsSync: () => existsSync(path),
    readFileSync: () => readFileSync(path),
    statSync: () => statSync(path).size,
    writeFileSync: () => writeFileSync(path, 'new'),
  })) {
    try { console.log(index, name, JSON.stringify(operation())); }
    catch (error) { console.log(index, name, error.name, error.message); }
  }
}
'''


def run(binary: str, root: Path, source: str, path_kinds: bool = False) -> tuple[int, bytes, bytes]:
    root.mkdir()
    if path_kinds:
        (root / 'file').write_text('hao')
        (root / 'dir').mkdir()
        (root / 'link-file').symlink_to('file')
        (root / 'link-dir').symlink_to('dir', target_is_directory=True)
        (root / 'broken-link').symlink_to('missing')
    script = root / 'probe.ts'
    script.write_text(source)
    result = subprocess.run((binary, str(script)), cwd=root, capture_output=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-fs-diff-') as directory:
        root = Path(directory)
        for index, source in enumerate((PATH_SOURCE, DATA_SOURCE, PATH_KIND_SOURCE)):
            path_kinds = source == PATH_KIND_SOURCE
            expected = run(legacy, root / f'legacy-{index}', source, path_kinds)
            actual = run(cyna, root / f'cyna-{index}', source, path_kinds)
            assert actual == expected, (index, expected, actual)
    print('filesystem differential: 84 argument forms, 23 data values, and 36 path kind operations matched')


if __name__ == '__main__':
    main()
