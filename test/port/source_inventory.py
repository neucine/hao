"""Check legacy Zig source and TypeScript declaration coverage."""

from pathlib import Path
import json
import re
import subprocess
import sys


root = Path(__file__).resolve().parents[2]
port = root
reference = sys.argv[1] if len(sys.argv) > 1 else "origin/legacy"
source = subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", reference, "--", "src"],
    cwd=root,
    text=True,
)
zig_files = {path.removeprefix("src/") for path in source.splitlines() if path.endswith(".zig")}
declaration_files = {path.removeprefix("src/") for path in source.splitlines() if path.endswith(".d.ts")}
shared_files = {
    path.removeprefix("src/") for path in source.splitlines()
    if path.endswith((".ts", ".html", ".json")) and not path.endswith(".d.ts")
}
if not zig_files:
    raise SystemExit(f"no Zig source files found in {reference}")

exceptions: dict[str, list[str]] = {}
for line in (port / "docs/PORT_PARITY.md").read_text().splitlines():
    columns = line.split("|")
    if len(columns) < 4 or ".zig`" not in columns[1]:
        continue
    legacy = re.findall(r"`([^`]+\.zig)`", columns[1])
    destinations = re.findall(r"`([^`]+)`", columns[2])
    for path in legacy:
        if path in exceptions:
            raise SystemExit(f"duplicate port mapping: {path}")
        exceptions[path] = destinations

c_only: dict[str, str] = {}
for line in (port / "docs/NATIVE_BOUNDARIES.md").read_text().splitlines():
    columns = line.split("|")
    if len(columns) < 4 or ".zig`" not in columns[1]:
        continue
    legacy = re.findall(r"`([^`]+\.zig)`", columns[1])
    destinations = re.findall(r"`([^`]+\.c)`", columns[2])
    if len(legacy) != 1 or len(destinations) != 1:
        raise SystemExit(f"invalid C only mapping: {line}")
    if legacy[0] in c_only:
        raise SystemExit(f"duplicate C only mapping: {legacy[0]}")
    c_only[legacy[0]] = destinations[0]

errors = []
abi_module = port / "src/hao_abi.cy"
if not abi_module.is_file() or not re.search(r'export c\("hao_', abi_module.read_text()):
    errors.append("missing central Hao Cyna ABI exports")
for candidate in (port / "src").rglob("*.cy"):
    if candidate == abi_module:
        continue
    if re.search(r'\bexport\s+c\s*\(', candidate.read_text()):
        errors.append(f"export outside central Hao ABI: {candidate.relative_to(port)}")
    if (port / "src/bridge") not in candidate.parents and re.search(
        r'\bextern\s+c\s*\(', candidate.read_text()
    ):
        errors.append(f"native import outside bridge: {candidate.relative_to(port)}")
for suffix in ("*.c", "*.h"):
    for candidate in (port / "src").rglob(suffix):
        if (port / "src/bridge") not in candidate.parents:
            errors.append(f"native source outside bridge: {candidate.relative_to(port)}")
bridge_sources = {
    candidate.relative_to(port).as_posix()
    for candidate in (port / "src/bridge").rglob("*.c")
}
declared_sources: dict[str, set[str]] = {}
for manifest_path in sorted(port.glob("cyna*.toml")):
    manifest_name = manifest_path.name
    manifest = manifest_path.read_text()
    c_section = re.search(r"(?ms)^\[c\]\n(.*?)(?=^\[|\Z)", manifest)
    sources = re.search(r"(?m)^sources\s*=\s*(\[[^\n]*\])", c_section.group(1)) if c_section else None
    if not sources:
        errors.append(f"missing C source list: {manifest_name}")
        continue
    declared = json.loads(sources.group(1))
    if len(declared) != len(set(declared)):
        errors.append(f"duplicate C source in {manifest_name}")
    declared_sources[manifest_name] = set(declared)
    if not set(declared) <= bridge_sources:
        errors.append(
            f"C source outside bridge in {manifest_name}: "
            f"{sorted(set(declared) - bridge_sources)}"
        )
for manifest_name in ("cyna.toml", "cyna.lib.toml"):
    declared = declared_sources.get(manifest_name)
    if declared is not None and declared != bridge_sources:
        errors.append(
            f"C source mismatch in {manifest_name}: "
            f"missing {sorted(bridge_sources - declared)}, "
            f"extra {sorted(declared - bridge_sources)}"
        )
for path in sorted(zig_files):
    source_path = Path(path)
    c_path = port / "src" / source_path.with_suffix(".c")
    cy_path = port / "src" / source_path.with_suffix(".cy")
    if c_path.is_file() and not cy_path.is_file() and path not in exceptions:
        expected = f"src/{source_path.with_suffix('.c')}"
        if c_only.get(path) != expected:
            errors.append(f"unexplained C only mapping: src/{path} -> {expected}")
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
for path, destination in sorted(c_only.items()):
    if path not in zig_files:
        errors.append(f"stale C only mapping: src/{path}")
    elif path in exceptions or (port / "src" / Path(path).with_suffix(".cy")).is_file():
        errors.append(f"C only mapping has a Cyna or layout port: src/{path}")
    elif not (port / destination).is_file():
        errors.append(f"missing C boundary: {destination}")
for path in sorted(declaration_files):
    destination = port / "src" / path
    if not destination.is_file():
        errors.append(f"missing declaration: src/{path}")
for path in sorted(shared_files):
    destination = port / "src" / path
    if not destination.is_file():
        errors.append(f"missing TypeScript source or asset: src/{path}")
for path in sorted(declaration_files | shared_files):
    if path in {"std/http/index.ts", "std/util/native.ts", "tsconfig.json"}:
        continue
    destination = port / "src" / path
    if destination.is_file():
        reference_bytes = subprocess.check_output(
            ["git", "show", f"{reference}:src/{path}"], cwd=root,
        )
        if destination.read_bytes() != reference_bytes:
            errors.append(f"unexpected content drift: src/{path}")
if errors:
    raise SystemExit("\n".join(errors))
print(f"source inventory: {len(zig_files)} Zig files mapped, {len(exceptions)} layout exceptions, {len(bridge_sources)} shared C bridge sources, {len(declaration_files)} TypeScript declarations, {len(shared_files)} TypeScript sources and assets")
