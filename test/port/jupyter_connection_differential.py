#!/usr/bin/env python3
"""Compare Jupyter connection port validation through the CLI."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

BASE = dict(transport='tcp', ip='127.0.0.1', shell_port=0,
            control_port=0, iopub_port=0, stdin_port=0, hb_port=0,
            key='', signature_scheme='hmac-sha256')
VALUES = ('1', '1.5', '1e2', '-1', '65536', 'null', '"1"',
          'true', '{}', '[]', '1.0')


def run(binary: Path, path: Path) -> tuple[int, bytes, bytes]:
    result = subprocess.run((str(binary), 'jupyter', '--connection-file', str(path)),
                            capture_output=True, timeout=3)
    return result.returncode, result.stdout, result.stderr


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: jupyter_connection_differential.py LEGACY_HAO CYNA_HAO',
              file=sys.stderr)
        return 2
    legacy, cyna = (Path(arg).resolve() for arg in sys.argv[1:])
    template = json.dumps(BASE)
    with tempfile.TemporaryDirectory(prefix='hao-jupyter-port-') as directory:
        path = Path(directory) / 'connection.json'
        for value in VALUES:
            path.write_text(template.replace('"shell_port": 0',
                                             f'"shell_port": {value}'))
            expected, actual = run(legacy, path), run(cyna, path)
            if actual != expected:
                print(value, 'legacy:', expected, 'cyna:', actual, file=sys.stderr)
                return 1
        path.write_text(template.replace('"shell_port": 0',
                                         '"shell_port": 01'))
        assert run(legacy, path)[2] == b'error: ZmqError\n'
        assert run(cyna, path)[2] == b'error: MissingField\n'
        path.write_text(template.replace('"shell_port": 0',
                                         '"shell_port": 1, "shell_port": null'))
        assert run(legacy, path)[2] == b'error: ZmqError\n'
        assert run(cyna, path)[2] == b'error: MissingField\n'
    print(f'Jupyter connection ports matched legacy: {len(VALUES)} forms; '
          'invalid JSON and duplicate keys rejected by Cyna')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
