#!/usr/bin/env python3
"""Package the browser executor and its imports for standalone deployment.

Build this alongside the platform archive from the same checkout. The manifest
records the compiler pin and source digests so consumers can retain the exact
runtime used to validate their Wasm artifact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "www" / "static"


def runtime_files() -> dict[str, bytes]:
    """Collect the entry module's static relative imports, rejecting escapes."""
    pending = ["signals.mjs"]
    files: dict[str, bytes] = {}
    while pending:
        name = pending.pop()
        if name in files:
            continue
        path = (STATIC / name).resolve()
        if not path.is_relative_to(STATIC.resolve()):
            raise ValueError(f"Runtime import escapes the static directory: {name}")
        data = path.read_bytes()
        files[name] = data
        for match in re.finditer(r'\bfrom\s+[\"\'](\./[^\"\']+)[\"\']', data.decode()):
            imported = (path.parent / match[1]).resolve()
            pending.append(imported.relative_to(STATIC.resolve()).as_posix())
    return files


def bundle(output: Path) -> None:
    """Write one reproducible archive with the complete browser module graph."""
    files = runtime_files()
    files["LICENSE"] = (ROOT / "LICENSE").read_bytes()
    manifest = {
        "roc_version": (ROOT / ".roc-version").read_text().strip(),
        "sha256": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())},
    }
    files["signals-runtime.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".test-out" / "signals-browser.zip")
    args = parser.parse_args()
    bundle(args.output)
    print(f"Created: {args.output}")


if __name__ == "__main__":
    main()
