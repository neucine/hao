#!/usr/bin/env python3
"""Compare lexical resolution of relative module imports with Zig."""
from pathlib import Path
import subprocess
import sys
import tempfile


SPECIFIERS = (
    './value.ts', '././value.ts', './a/../value.ts',
    './a//../value.ts', './a/b/../../value.ts',
    './a/./nested.ts', './a/b/../nested.ts',
    '../outside.ts', './a/../../outside.ts',
    './a/b/../../../outside.ts', './missing/../value.ts',
)


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-module-path-') as directory:
        root = Path(directory)
        base = root / 'base'
        base.mkdir()
        (base / 'a' / 'b').mkdir(parents=True)
        (base / 'value.ts').write_text('export const value = 17;\n')
        (base / 'a' / 'nested.ts').write_text('export const value = 23;\n')
        (root / 'outside.ts').write_text('export const value = 31;\n')
        for index, specifier in enumerate(SPECIFIERS):
            script = base / f'probe-{index}.ts'
            script.write_text(f'import {{ value }} from {specifier!r}; console.log(value);\n')
            expected = run(legacy, script)
            actual = run(cyna, script)
            assert actual == expected, (specifier, expected, actual)
    print(f'module paths: {len(SPECIFIERS)} relative imports matched legacy')


if __name__ == '__main__':
    main()
