"""Check the public module loader failures against legacy's message matrix."""

import json
import pathlib
import subprocess
import sys
import tempfile


runtime = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="hao-package-diagnostics-") as directory:
    root = pathlib.Path(directory)
    modules = root / "node_modules"
    modules.mkdir()
    cases = {
        "missing": (None, None, "Cannot resolve module"),
        "manifest": (None, "index.ts", "Package manifest not found"),
        "bad-json": ("{", "index.ts", "Cannot resolve module"),
        "commonjs": ({"type": "commonjs", "main": "index.js"}, "index.js", "CommonJS packages are not supported"),
        "no-export": ({"type": "module"}, "index.ts", "Package export not found"),
        "unsupported": ({"exports": "./index.js"}, "index.js", "Package entry is not ESM-compatible"),
        "entry-missing": ({"exports": "./absent.ts"}, None, "Cannot resolve module"),
        "empty-main": ({"type": "module", "main": ""}, None, "Package entry is not ESM-compatible"),
        "trailing-file": ({"type": "module", "exports": "./index.ts/"}, "index.ts", "Cannot resolve module"),
    }
    for name, (manifest, entry, reason) in cases.items():
        if name != "missing":
            package = modules / name
            package.mkdir()
            if manifest is not None:
                (package / "package.json").write_text(
                    manifest if isinstance(manifest, str) else json.dumps(manifest)
                )
            if entry is not None:
                (package / entry).write_text("export const value = 1;\n")
        source = root / f"{name}.ts"
        source.write_text(f'import "{name}";\n')
        result = subprocess.run([runtime, source], capture_output=True, text=True)
        assert result.returncode == 1 and result.stdout == "", (name, result)
        assert result.stderr == f"{reason}: {name} (from {source})\n", (name, result)

    absolute = modules / "absolute"
    absolute.mkdir()
    (absolute / "package.json").write_text(json.dumps({"type": "module", "exports": "/index.ts"}))
    (absolute / "index.ts").write_text("export const value = 42;\n")
    source = root / "absolute.ts"
    source.write_text('import { value } from "absolute"; console.log(value);\n')
    result = subprocess.run([runtime, source], capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout == "42\n" and result.stderr == "", result

    (absolute / "package.json").write_text(json.dumps({"type": "module", "exports": "//index.ts"}))
    result = subprocess.run([runtime, source], capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout == "42\n" and result.stderr == "", result

    relative = root / "relative.ts"
    relative.write_text('import "./absent.ts";\n')
    result = subprocess.run([runtime, relative], capture_output=True, text=True)
    assert result.returncode == 1 and result.stdout == "", result
    assert result.stderr == "Module source not found\n", result

    oversized = root / "oversized.ts"
    oversized.write_text('import "./oversized-source.ts";\n')
    (root / "oversized-source.ts").write_bytes(b"a" * (10 * 1024 * 1024 + 1))
    directory = root / "directory.ts"
    directory.write_text('import "./source-directory";\n')
    (root / "source-directory").mkdir()
    for source in (oversized, directory):
        result = subprocess.run([runtime, source], capture_output=True, text=True)
        assert result.returncode == 1 and result.stdout == "", result
        assert result.stderr == "Module source not found\n", result

print("Package diagnostics matched legacy")
