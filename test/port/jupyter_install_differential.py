#!/usr/bin/env python3
"""Check the port's absolute Jupyter kernel path against the Zig behavior."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def install(binary: Path, cwd: Path, home: Path) -> subprocess.CompletedProcess:
    environment = {**os.environ, 'HOME': str(home)}
    environment.pop('HAO_JUPYTER_KERNEL_DIR', None)
    return subprocess.run((str(binary), 'jupyter', 'install'), cwd=cwd,
                          env=environment, capture_output=True, timeout=10)


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: jupyter_install_differential.py LEGACY_HAO CYNA_HAO',
              file=sys.stderr)
        return 2
    legacy, cyna = (Path(arg).resolve() for arg in sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix='hao-jupyter-install-') as directory:
        root = Path(directory)
        cwd, home = root / 'work', root / 'home'
        cwd.mkdir()
        home.mkdir()
        zig = install(legacy, cwd, home)
        assert (zig.returncode, zig.stdout, zig.stderr) == (
            1, b'', b'error: FileWriteFailed\n'), zig
        port = install(cyna, cwd, home)
        path = home / 'Library/Jupyter/kernels/hao/kernel.json'
        assert port.returncode == 0 and path.is_file(), port
        spec = json.loads(path.read_text())
        assert spec['argv'] == [str(cyna), 'jupyter', '--connection-file',
                                '{connection_file}'], spec
        assert port.stdout == f'Installed kernel to {path}\n'.encode(), port
    print('Jupyter installer writes the absolute HOME path; Zig fails with FileWriteFailed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
