#!/usr/bin/env python3
"""Compare legacy and Cyna dotenv parsing through the public process API."""
import os
from pathlib import Path
import random
import string
import subprocess
import sys
import tempfile


def outcome(binary: str, script: Path, dotenv: Path) -> tuple[int, bytes, bytes]:
    environment = os.environ.copy()
    environment["DOTENV"] = str(dotenv)
    environment.pop("HAO_PORT_FUZZ", None)
    result = subprocess.run((binary, str(script)), env=environment,
                            capture_output=True, timeout=5)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy, cyna = sys.argv[1:3]
    random.seed(12)
    values = ["", "x", " x ", "x y", '"x y"', "'x y'", '"x\\ny"',
              "a#b", "a # b", "a\t#b", '"a#b"', '"a" #b', "'a'#b",
              '"unterminated', "abc\\", "a\r", "a\x00b", '""', "''",
              "é", "😀", "\\#x"]
    lines = [(prefix + "HAO_PORT_FUZZ=" + value + suffix).encode()
             for value in values
             for prefix in ("", "export ", " export ", "export\t")
             for suffix in ("\n", "\r\n")]
    for _ in range(100):
        value = "".join(random.choices(string.ascii_letters + string.digits + " #\\\"'\t",
                                       k=random.randrange(0, 20)))
        lines.append(("HAO_PORT_FUZZ=" + value + "\n").encode())

    key_forms = ["HAO_PORT_FUZZ", " HAO_PORT_FUZZ", "HAO_PORT_FUZZ ",
                 "HAO_PORT_FUZZ\t", "HAO_PORT_FUZZ\x00", "HAO-PORT-FUZZ",
                 "HAO.PORT.FUZZ", "HAO PORT FUZZ", "1HAO_PORT_FUZZ",
                 "HAO_PORT_FUZZ\r", "export HAO_PORT_FUZZ",
                 "export\tHAO_PORT_FUZZ", "EXPORT HAO_PORT_FUZZ"]
    key_values = ["x", "", " x ", '"x"', "x # c", "\x00", "\\x"]
    lines.extend((key + "=" + value + "\n").encode()
                 for key in key_forms for value in key_values)
    random.seed(17)
    for _ in range(100):
        key = "".join(random.choices(string.ascii_letters + string.digits + " _-\t\r",
                                     k=random.randrange(0, 25)))
        lines.append((key + "=x\n").encode())

    with tempfile.TemporaryDirectory(prefix="hao-dotenv-diff-") as directory:
        root = Path(directory)
        script = root / "probe.ts"
        script.write_text("import { getEnv } from 'std:process'; "
                          "console.log(JSON.stringify(getEnv('HAO_PORT_FUZZ')));\n")
        dotenv = root / ".env"
        for index, line in enumerate(lines):
            dotenv.write_bytes(line)
            expected = outcome(legacy, script, dotenv)
            actual = outcome(cyna, script, dotenv)
            assert actual == expected, (index, line, expected, actual)
    print(f"dotenv differential: {len(lines)} Zig/Cyna forms matched")


if __name__ == "__main__":
    main()
