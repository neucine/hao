"""Check that every legacy Zig source has a Cyna port location."""

from pathlib import Path
import re
import subprocess
import sys


root = Path(__file__).resolve().parents[2]
port = root / "cyna"
reference = sys.argv[1] if len(sys.argv) > 1 else "origin/legacy"
source = subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", reference, "--", "src"],
    cwd=root,
    text=True,
)
zig_files = {path.removeprefix("src/") for path in source.splitlines() if path.endswith(".zig")}
if not zig_files:
    raise SystemExit(f"no Zig source files found in {reference}")

exceptions: dict[str, list[str]] = {}
for line in (port / "PORT_PARITY.md").read_text().splitlines():
    columns = line.split("|")
    if len(columns) < 4 or ".zig`" not in columns[1]:
        continue
    legacy = re.findall(r"`([^`]+\.zig)`", columns[1])
    destinations = re.findall(r"`([^`]+)`", columns[2])
    for path in legacy:
        if path in exceptions:
            raise SystemExit(f"duplicate port mapping: {path}")
        exceptions[path] = destinations

errors = []
for path in sorted(zig_files):
    source_path = Path(path)
    matching = [
        port / "src" / source_path.with_suffix(extension)
        for extension in (".cy", ".c", ".ts")
    ]
    if any(candidate.is_file() for candidate in matching):
        continue
    destinations = exceptions.get(path)
    if not destinations:
        errors.append(f"missing port: src/{path}")
    else:
        for destination in destinations:
            if not (port / destination).exists():
                errors.append(f"missing mapped location for src/{path}: {destination}")

for path in sorted(exceptions.keys() - zig_files):
    errors.append(f"stale port mapping: src/{path}")
if errors:
    raise SystemExit("\n".join(errors))
print(f"source inventory: {len(zig_files)} Zig files mapped, {len(exceptions)} layout exceptions")
