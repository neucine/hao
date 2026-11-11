"""Check Jupyter connection file diagnostics before opening sockets."""

from pathlib import Path
import subprocess
import sys
import tempfile


runtime = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="hao-jupyter-cli-") as directory:
    root = Path(directory)
    path = root / "connection.json"
    for content, target, error in (
        (None, path, "FileNotFound"),
        ("{", path, "MissingField"),
        ("{}", path, "MissingField"),
        (None, root, "FileReadFailed"),
        ("x" * (64 * 1024 + 1), path, "StreamTooLong"),
    ):
        if content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(content)
        result = subprocess.run(
            (runtime, "jupyter", "--connection-file", str(target)),
            capture_output=True,
        )
        assert (result.returncode, result.stdout, result.stderr) == (
            1, b"", f"error: {error}\n".encode()
        ), (target, result)
