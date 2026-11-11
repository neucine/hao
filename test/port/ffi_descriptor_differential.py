#!/usr/bin/env python3
"""Compare Zig and Cyna FFI descriptor shape and type validation."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


CASES = [
    None, 0, 1, False, True, 'x', [], {},
    {'sqrt': []}, {'sqrt': {}}, {'sqrt': {'args': []}},
    {'sqrt': {'args': [], 'returns': 'f64'}},
    {'sqrt': {'args': ['f64'], 'returns': 'f64'}},
    {'sqrt': {'args': ['bad'], 'returns': 'f64'}},
    {'sqrt': {'args': 'f64', 'returns': 'f64'}},
    {'sqrt': {'args': [0], 'returns': 'f64'}},
    {'sqrt': {'args': ['f64'], 'returns': 'bad'}},
    {'missing': {'args': [], 'returns': 'void'}},
]


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-ffi-descriptor-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text("import { openNative, closeNative } from 'std:ffi/native';\n"
                          'const cases = ' + json.dumps(CASES) + ';\n'
                          'for (let i = 0; i < cases.length; i++) {\n'
                          "  try { const handle = openNative('m', cases[i]); console.log(i, 'ok'); closeNative(handle); }\n"
                          '  catch (error) { console.log(i, error.name, error.message); }\n'
                          '}\n')
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print(f'FFI descriptors: {len(CASES)} Zig/Cyna forms matched')


if __name__ == '__main__':
    main()
