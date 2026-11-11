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
    {'sqrt': {'args': ['void'], 'returns': 'f64'}},
    {'sqrt': {'args': ['i32'] * 8, 'returns': 'f64'}},
    {'sqrt': {'args': ['i32'] * 9, 'returns': 'f64'}},
    {'sqrt': {'args': ['i32'] * 100, 'returns': 'f64'}},
]


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix='hao-ffi-descriptor-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text("import { openNative, closeNative, callNative } from 'std:ffi/native';\n"
                          'const cases = ' + json.dumps(CASES) + ';\n'
                          'for (let i = 0; i < cases.length; i++) {\n'
                          "  try { const handle = openNative('m', cases[i]); console.log(i, 'ok'); closeNative(handle); }\n"
                          '  catch (error) { console.log(i, error.name, error.message); }\n'
                          '}\n'
                          "for (const [label, spec] of [['args', { get args() { throw Error('args boom'); }, returns: 'f64' }], "
                          "['returns', { args: ['f64'], get returns() { throw Error('returns boom'); } }]]) {\n"
                          "  try { openNative('m', { sqrt: spec }); }\n"
                          "  catch (error) { console.log(label, error.name, error.message); }\n"
                          '}\n'
                          "let argsReads = 0, returnReads = 0;\n"
                          "const spec = { get args() { argsReads++; return ['f64']; }, "
                          "get returns() { returnReads++; return 'f64'; } };\n"
                          "const handle = openNative('m', { sqrt: spec }); closeNative(handle);\n"
                          'console.log("getter reads", argsReads, returnReads);\n'
                          "const throwingArgs = ['f64'];\n"
                          "Object.defineProperty(throwingArgs, '0', { get() { throw Error('element boom'); } });\n"
                          "const argumentCases = [new Array(1), throwingArgs, "
                          "new Proxy(['f64'], { get(target, key) { "
                          "if (key === '0') throw Error('proxy element boom'); "
                          "return Reflect.get(target, key); } })];\n"
                          'for (let i = 0; i < argumentCases.length; i++) {\n'
                          "  try { const h = openNative('m', { sqrt: { args: argumentCases[i], returns: 'f64' } }); "
                          "console.log('argument', i, 'ok'); closeNative(h); }\n"
                          "  catch (error) { console.log('argument', i, error.name, error.message); }\n"
                          '}\n'
                          "const voidHandle = openNative('m', { sqrt: { args: ['void'], returns: 'f64' } });\n"
                          "try { callNative(voidHandle, 'sqrt', [0]); }\n"
                          "catch (error) { console.log('void call', error.name, error.message); }\n"
                          'closeNative(voidHandle);\n'
                          "for (const [label, types] of [['int', Array(9).fill('i32')], "
                          "['float', Array(9).fill('f64')], "
                          "['mixed', ['f64', ...Array(8).fill('i32')]], "
                          "['ten', Array(10).fill('i32')]]) {\n"
                          "  const h = openNative('m', { sqrt: { args: types, returns: 'f64' } });\n"
                          "  try { callNative(h, 'sqrt', types.map(() => 1)); }\n"
                          "  catch (error) { console.log(label, error.name, error.message); }\n"
                          "  closeNative(h);\n"
                          "}\n")
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print(f'FFI descriptors: {len(CASES)} shapes and 11 getter, array, or call outcomes matched')


if __name__ == '__main__':
    main()
