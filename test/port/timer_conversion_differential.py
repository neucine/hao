#!/usr/bin/env python3
"""Compare public timer argument conversion with the Zig legacy executable."""
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE = r'''const delays = [undefined, null, false, true, 0, -1, 1.9, NaN,
  Infinity, -Infinity, '', '2', 'bad', [], [1], {}, Symbol('delay'),
  { valueOf() { throw Error('boom') } }];
for (const value of delays) {
  try {
    const id = setTimeout(() => {}, value);
    clearTimeout(id);
    console.log(JSON.stringify([typeof id, id]));
  } catch (error) { console.log(error.name + ':' + error.message); }
}
for (const value of delays) {
  try { clearTimeout(value); console.log('clear ok'); }
  catch (error) { console.log(error.name + ':' + error.message); }
}
'''


def run(binary: Path, source: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(binary), str(source)], cwd=source.parent,
                          capture_output=True, text=True, timeout=15)


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: timer_conversion_differential.py LEGACY_HAO CYNA_HAO', file=sys.stderr)
        return 2
    binaries = [Path(arg).resolve() for arg in sys.argv[1:]]
    with tempfile.TemporaryDirectory(prefix='hao-timer-parity-') as directory:
        source = Path(directory) / 'timer.ts'
        source.write_text(SOURCE)
        legacy, cyna = (run(binary, source) for binary in binaries)
    if (legacy.returncode, legacy.stdout, legacy.stderr) != (cyna.returncode, cyna.stdout, cyna.stderr):
        print('timer conversion differs from Zig', file=sys.stderr)
        print('legacy:', repr((legacy.returncode, legacy.stdout, legacy.stderr)), file=sys.stderr)
        print('cyna:', repr((cyna.returncode, cyna.stdout, cyna.stderr)), file=sys.stderr)
        return 1
    print(f'timer conversion matched legacy: {len(legacy.stdout.splitlines())} outcomes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
