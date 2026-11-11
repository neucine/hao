"""Check startup configuration errors before CLI dispatch."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


runtime = sys.argv[1]
bad = [
    ("RUNTIME_QJS_STACK_SIZE", "invalid"),
    ("RUNTIME_TELEMETRY_CONSOLE", "maybe"),
    ("RUNTIME_NATIVE_STACK_TRACE", "maybe"),
]
for key, value in bad:
    environment = os.environ.copy()
    environment[key] = value
    for args in (("--version",), ("/tmp/hao-missing-parity-file.ts",), ("test",)):
        result = subprocess.run((runtime, *args), env=environment, capture_output=True)
        assert (result.returncode, result.stdout, result.stderr) == (
            1, b"", b"error: BadConfigValue\n"
        ), (key, args, result)

environment = os.environ.copy()
environment["RUNTIME_TELEMETRY_TRACE_RECORDS"] = "1048577"
result = subprocess.run((runtime, "--version"), env=environment, capture_output=True)
assert result.returncode == 0 and result.stdout.startswith(b"hao ") and result.stderr == b"", result
environment["RUNTIME_TELEMETRY_CONSOLE"] = "1"
result = subprocess.run((runtime, "--version"), env=environment, capture_output=True)
assert result.returncode == 0 and result.stdout.startswith(b"hao ") and result.stderr == b"", result
result = subprocess.run((runtime, "/tmp/hao-missing-parity-file.ts"), env=environment, capture_output=True)
assert (result.returncode, result.stdout, result.stderr) == (
    1, b"", b"error: TelemetryTraceLimitExceeded\n"
), result

with tempfile.TemporaryDirectory(prefix="hao-dotenv-cli-") as directory:
    base = Path(directory)
    large = base / "large.env"
    large.write_bytes(b"A" * (1024 * 1024 + 1))
    for path, error in (
        (base / "missing.env", b"FileNotFound"),
        (base, b"FileReadFailed"),
        (large, b"StreamTooLong"),
    ):
        environment = os.environ.copy()
        environment["DOTENV"] = str(path)
        result = subprocess.run((runtime, "--version"), env=environment, capture_output=True)
        assert (result.returncode, result.stdout, result.stderr) == (
            1, b"", b"error: " + error + b"\n"
        ), (path, result)
    invalid = base / "invalid.env"
    for content, error in (
        (b"X\x00Y=hello\n", b"InvalidEnvName"),
        (b"X=he\x00llo\n", b"InvalidEnvValue"),
    ):
        invalid.write_bytes(content)
        environment["DOTENV"] = str(invalid)
        result = subprocess.run((runtime, "--version"), env=environment, capture_output=True)
        assert (result.returncode, result.stdout, result.stderr) == (
            1, b"", b"error: " + error + b"\n"
        ), (content, result)
