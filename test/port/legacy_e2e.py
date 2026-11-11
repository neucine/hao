#!/usr/bin/env python3
"""Run the unchanged Zig legacy end to end suite with the Cyna binary."""

import io
import subprocess
import tarfile
import tempfile
from pathlib import Path
import sys


repo = Path(__file__).resolve().parents[2]
runtime = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (repo / "build/hao-cyna").resolve()
legacy = next(
    (
        ref
        for ref in ("refs/heads/legacy", "refs/remotes/origin/legacy")
        if subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", ref], cwd=repo
        ).returncode == 0
    ),
    None,
)
if legacy is None:
    raise SystemExit("legacy branch is unavailable; fetch origin/legacy first")
archive = subprocess.run(
    ["git", "archive", "--format=tar", legacy, "test/e2e"],
    cwd=repo,
    check=True,
    capture_output=True,
).stdout

with tempfile.TemporaryDirectory(prefix="hao-legacy-e2e-") as directory:
    workspace = Path(directory)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(workspace)
    alias = workspace / "zig-out/bin/hao"
    alias.parent.mkdir(parents=True)
    alias.symlink_to(runtime)
    result = subprocess.run([runtime, "test", "test/e2e"], cwd=workspace)

raise SystemExit(result.returncode)
