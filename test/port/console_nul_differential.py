#!/usr/bin/env python3
"""Compare NUL handling in public inspection and console output."""
from pathlib import Path
import subprocess
import sys
import tempfile


SOURCE = """import { inspect } from 'std:util';
for (const value of ['a\\0b', { x: 'a\\0b' }, ['a\\0b'],
  { repr() { return { data: 'a\\0b' }; } },
  { dtype: 'x', shape: [], toString() { return 'a\\0b'; } },
  { ['a\\0b']: 1 },
  Object.defineProperty(function named() {}, 'name', { value: 'a\\0b' })]) {
  console.log(JSON.stringify(inspect(value)));
  console.log(value);
}
"""


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix="hao-console-nul-") as directory:
        script = Path(directory) / "probe.ts"
        script.write_text(SOURCE)
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print("console inspection: seven NUL containing values matched legacy")


if __name__ == "__main__":
    main()
