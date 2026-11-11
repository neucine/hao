#!/usr/bin/env python3
"""Run every retained Zig/Cyna public behavior comparison."""
from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: run_differentials.py LEGACY_HAO CYNA_HAO', file=sys.stderr)
        return 2
    legacy, port = (str(Path(arg).resolve()) for arg in sys.argv[1:])
    scripts = sorted(Path(__file__).parent.glob('*differential.py'))
    for script in scripts:
        result = subprocess.run((sys.executable, str(script), legacy, port),
                                capture_output=True, text=True, timeout=90)
        print(f'{script.name}: {result.stdout.strip()}', flush=True)
        if result.returncode:
            print(result.stderr, file=sys.stderr)
            return result.returncode
    print(f'All {len(scripts)} Zig/Cyna differentials passed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
