#!/usr/bin/env python3
"""Compare Zig and Cyna FFI policy validation and error precedence."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


DECLARATIONS = 'double sqrt(double x); void fill(uint8_t *data, size_t len);'


def policy_cases() -> list[object]:
    forms: list[object] = []
    for strategy in (None, 'runtime-default', 'relative-first', 'system-first',
                     'bad', '', 0, True, [], {}):
        for paths in (None, [], ['/tmp'], [3], ['/tmp', 2], [], {}, 'x'):
            search = {}
            if strategy is not None:
                search['strategy'] = strategy
            if paths is not None:
                search['paths'] = paths
            forms.append({'search': search})
    for returns in (None, {}, {'kind': 'handle'}, {'kind': 'handle', 'type': 'Foo'},
                    {'kind': 'value'}, {'out': 'x'}, {'out': 'data'},
                    {'type': 'Foo'}, {'kind': 'handle', 'out': 'data'}):
        if returns is not None:
            forms.append({'functions': {'sqrt': {'returns': returns}}})
    for errors in (None, {}, {'kind': 'status'}, {'kind': 'null'},
                   {'kind': 'sentinel'}, {'kind': 'bad'}, {'ok': 0},
                   {'value': -1}, {'code': 'x'}, {'message': 'bad'},
                   {'message': {'from': 'sqrt'}},
                   {'message': {'from': 'missing'}},
                   {'message': {'from': 'fill', 'arg': 'data'}},
                   {'message': {'from': 'fill', 'arg': 'missing'}}):
        if errors is not None:
            forms.append({'functions': {'sqrt': {'errors': errors}}})
    for pointer in ('data', 'len', 'missing'):
        for length in ('data', 'len', 'missing'):
            for element in ('u8', 'f64', 'bad', None):
                for direction in (None, 'in', 'out', 'inout', 'bad'):
                    buffer = {'length': length}
                    if element is not None:
                        buffer['element'] = element
                    if direction is not None:
                        buffer['direction'] = direction
                    forms.append({'functions': {'fill': {'buffers': {pointer: buffer}}}})
    for handles in (0, 1, True, False, 'x', [], {'Foo': None}):
        forms.append({'handles': handles})
    return forms


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    forms = policy_cases()
    with tempfile.TemporaryDirectory(prefix='hao-ffi-policy-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text("import { prepareNative } from 'std:ffi/c/native';\n"
                          'const cases = ' + json.dumps(forms) + ';\n'
                          'for (let i = 0; i < cases.length; i++) {\n'
                          "  try { console.log(i, JSON.stringify(prepareNative('m', "
                          + json.dumps(DECLARATIONS) + ", cases[i]))); }\n"
                          '  catch (error) { console.log(i, error.name, error.code, error.message); }\n'
                          '}\n')
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print(f'FFI policies: {len(forms)} Zig/Cyna forms matched')


if __name__ == '__main__':
    main()
