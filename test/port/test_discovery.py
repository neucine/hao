#!/usr/bin/env python3
"""Compare Zig and Cyna test path discovery, including symlinks."""
import pathlib
import re
import subprocess
import sys
import tempfile


def run(binary: str, path: pathlib.Path) -> tuple[int, str, str]:
    result = subprocess.run([binary, "test", str(path)], capture_output=True, text=True, timeout=10)
    stderr = re.sub(r"(?m)^(?:\x1b\[[0-9;]*m)*Time:.*\n", "", result.stderr)
    stderr = re.sub(r"(?m)^Time:.*\n", "", stderr)
    stderr = re.sub(r"\([0-9]+(?:\.[0-9]+)?(?:us|ms|s)\)", "(TIME)", stderr)
    return result.returncode, result.stdout, stderr


def main() -> None:
    zig, cyna = sys.argv[1:3]
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        suite = root / "suite.test.ts"
        suite.mkdir()
        (suite / "a.test.ts").write_text("import { test } from 'std:test'; test('a', () => {});\n")
        regular = root / "regular.test.ts"
        regular.write_text("import { test } from 'std:test'; test('b', () => {});\n")
        (root / "linkdir").symlink_to(suite, target_is_directory=True)
        (root / "link.test.ts").symlink_to(regular)
        (root / "broken.test.ts").symlink_to(root / "absent.test.ts")
        cases = (suite, regular, root / "linkdir", root / "link.test.ts",
                 root / "broken.test.ts", root / "absent.test.ts", root)
        for path in cases:
            expected, actual = run(zig, path), run(cyna, path)
            assert expected == actual, f"{path.name}: Zig {expected!r}; Cyna {actual!r}"
    print(f"test discovery: {len(cases)} Zig/Cyna paths matched")


if __name__ == "__main__":
    main()
