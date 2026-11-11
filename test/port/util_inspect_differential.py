#!/usr/bin/env python3
"""Compare utility inspection across nested values and option limits."""
from pathlib import Path
import subprocess
import sys
import tempfile


SOURCE = r'''import { inspect } from 'std:util';
const values = [
  new Array(3), [undefined, null, 1], { a: undefined, b: null },
  { ['']: 1 }, { ['a\0b']: 2 },
  Object.defineProperty(function foo() {}, 'name', { value: '\0suffix' }),
  new Date('2020-01-01T00:00:00Z'), new Error('oops'),
  Object.create(null), { toString() { return 'x\0y' }, dtype: 'f64', shape: [1] },
  { repr() { return { data: false }; } },
  { repr() { return { data: Symbol('bad') }; }, x: 1 },
];
const options = [undefined, {maxDepth:0}, {maxDepth:1}, {maxArrayLength:0},
  {maxArrayLength:1}, {maxStringLength:0}, {maxStringLength:1},
  {maxStringLength:NaN}, {maxStringLength:-Infinity}];
for (let i = 0; i < values.length; i++) for (let j = 0; j < options.length; j++) {
  try { console.log(i, j, JSON.stringify(inspect(values[i], options[j]))); }
  catch (error) { console.log(i, j, 'ERROR', error.name, error.message); }
}
'''


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix="hao-util-inspect-") as directory:
        script = Path(directory) / "probe.ts"
        script.write_text(SOURCE)
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert expected[0] == 0 and not expected[2]
        assert len(expected[1].splitlines()) == 108
        assert actual == expected, (expected, actual)
    print("utility inspection: 108 value and option combinations matched legacy")


if __name__ == "__main__":
    main()
