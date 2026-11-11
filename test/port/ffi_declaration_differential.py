#!/usr/bin/env python3
"""Compare Zig and Cyna C declaration parsing and error precedence."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def declarations() -> list[str]:
    forms = []
    for result in ('void', 'int', 'int32_t', 'uint32_t', 'size_t', 'double',
                   'float', 'char *', 'const char *', 'void *', 'char const *'):
        for arg in ('void', 'int x', 'double x', 'char *x', 'const char *x',
                    'size_t n', 'int32_t x, int32_t y'):
            forms.append(f'{result} f({arg});')
    for name in ('Foo', 'Bar', '_Foo'):
        for body in ('int32_t x;', 'double x; char *name;', 'int32_t x:3;', ''):
            forms.append(f'typedef struct {{ {body} }} {name}; void f({name} *value);')
    for prefix in ('static', 'extern', 'inline', 'volatile', 'const', 'restrict',
                   'unsigned', 'signed'):
        forms.extend((f'{prefix} int f(int x);', f'int f({prefix} int x);'))
    for qualifier in ('static', 'extern', 'inline', 'volatile', 'restrict',
                      'const', 'signed', 'unsigned'):
        for type_name in ('int', 'double', 'int32_t', 'char *'):
            forms.extend((f'{qualifier} {type_name} f(void);',
                          f'void f({qualifier} {type_name} x);'))
    for base in ('char', 'uint8_t', 'int32_t', 'double', 'void', 'Foo'):
        for modifier in ('', 'const ', 'volatile ', 'restrict ', 'static ',
                         'extern ', 'inline '):
            for pointer in ('', ' *', ' **', ' * const', ' const *', ' volatile *'):
                forms.append(f'void f({modifier}{base}{pointer} value);')
    for source in ('void f(void);', 'int32_t f(int32_t x);',
                   'typedef struct { int32_t x; } Foo; void f(Foo *x);'):
        for start, end in (('/*hi*/', ''), ('//hi\n', ''), ('', '/*tail*/'),
                           ('', '//tail\n'), ('/*unterminated', ''),
                           ('#include <x>', '')):
            forms.append(start + source + end)
    forms.extend(('void f(void value);', 'void f(const void value);',
                  'void f(volatile void value);', 'void f(void *value);',
                  'void f(const void *value);', 'const void f(void);',
                  'volatile void f(void);', 'void f(const void);',
                  'void f(void const);', 'void f(void *);',
                  'void f(const void *);', 'void f(void, const void value);',
                  'void f(void, void value);',
                  'void f(void, volatile void value);',
                  'void f(void, char *value);', 'void f(void, int value);',
                  'void f(void, static int value);',
                  'void f(void, const void);', 'void f(void, void);',
                  'void f(const void, int x);',
                  'void f(const void, const void value);'))
    return forms


def run(binary: str, script: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((binary, str(script)), capture_output=True, timeout=15)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy = str(Path(sys.argv[1]).resolve())
    cyna = str(Path(sys.argv[2]).resolve())
    forms = declarations()
    with tempfile.TemporaryDirectory(prefix='hao-ffi-declarations-') as directory:
        script = Path(directory) / 'probe.ts'
        script.write_text("import { prepareNative } from 'std:ffi/c/native';\n"
                          'const cases = ' + json.dumps(forms) + ';\n'
                          "for (let i = 0; i < cases.length; i++) {\n"
                          "  try { console.log(i, JSON.stringify(prepareNative('m', cases[i]))); }\n"
                          "  catch (error) { console.log(i, error.name, error.code, error.message); }\n"
                          '}\n')
        expected = run(legacy, script)
        actual = run(cyna, script)
        assert actual == expected, (expected, actual)
    print(f'FFI declarations: {len(forms)} Zig/Cyna forms matched')


if __name__ == '__main__':
    main()
