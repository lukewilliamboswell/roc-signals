#!/usr/bin/env python3
"""Build the production Roc Signals artifact for js-framework-benchmark."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent
ADAPTER = Path(
    os.environ.get("ROC_SIGNALS_ADAPTER_DIR")
    or ROOT / "benchmarks" / "js-framework-benchmark" / "roc-signals-keyed"
).resolve()
OUTPUT = ADAPTER / "dist"
FIXTURE = ROOT / "examples" / "_fixtures" / "js-framework-benchmark" / "main.roc"
RUNTIME_FILES = (
    "signals.mjs",
    "controlled_input_policy.mjs",
    "wasm_memory_views.mjs",
)


def run(command: list[str | Path]) -> None:
    """Run one required build command from the repository root."""
    print("==>", " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], cwd=ROOT, check=True)


def resolve_executable(value: str, label: str) -> str:
    """Resolve a configured executable and fail with an actionable message."""
    resolved = shutil.which(value)
    if resolved is None:
        raise SystemExit(f"missing {label}: {value}")
    return resolved


def display_path(path: Path) -> str:
    """Display in-tree output compactly and copied adapter output honestly."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def main() -> None:
    """Produce the ordinary optimized Wasm app and its matching JS runtime."""
    roc = resolve_executable(os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc", "Roc compiler")
    resolve_executable("zig", "Zig compiler")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    run(["zig", "build", "build-test-hosts", "-Doptimize=ReleaseFast"])
    run(
        [
            roc,
            "build",
            "--target=wasm32",
            "--opt=speed",
            "--no-cache",
            f"--output={OUTPUT / 'app.wasm'}",
            FIXTURE,
        ]
    )
    for runtime_file in RUNTIME_FILES:
        shutil.copyfile(ROOT / "www" / "static" / runtime_file, OUTPUT / runtime_file)
    shutil.copyfile(ADAPTER / "src" / "main.mjs", OUTPUT / "main.mjs")
    print(f"Built {display_path(OUTPUT)}/", flush=True)


if __name__ == "__main__":
    main()
