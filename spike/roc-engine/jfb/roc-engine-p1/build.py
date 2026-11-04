#!/usr/bin/env python3
"""Build the pure-Roc-engine (platform-roc) js-framework-benchmark artifact.

Phase 1 spike adapter. Produces dist/app.wasm, dist/runtime.mjs and
dist/main.mjs. Environment:
  ROC_BIN / ROC   Roc compiler (required: the pinned nightly)
  ZIG             Zig 0.16 compiler (default: zig on PATH)
  ROC_ENGINE_OPT  Roc --opt level (default: speed)
  ROC_ENGINE_OUT  output directory (default: <adapter>/dist)
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess

ADAPTER = Path(__file__).resolve().parent


def signals_root() -> Path:
    configured = os.environ.get("ROC_SIGNALS_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()
    return ADAPTER.parents[2]


def run(command: list[str | Path]) -> None:
    print("==>", " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True)


def main() -> None:
    root = signals_root()
    platform = root / "platform-roc"
    roc = os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc"
    zig = os.environ.get("ZIG") or "zig"
    opt = os.environ.get("ROC_ENGINE_OPT", "speed")
    output = Path(os.environ.get("ROC_ENGINE_OUT") or ADAPTER / "dist")
    output.mkdir(parents=True, exist_ok=True)
    (platform / "targets" / "wasm32").mkdir(parents=True, exist_ok=True)
    run([zig, "build-obj", platform / "host" / "host.zig", "-target", "wasm32-freestanding",
         "-O", "ReleaseFast", "-fstrip", f"-femit-bin={platform / 'targets' / 'wasm32' / 'host.wasm'}"])
    run([roc, "build", "--target=wasm32", f"--opt={opt}", "--no-cache",
         f"--output={output / 'app.wasm'}", ADAPTER / "app" / "main.roc"])
    shutil.copyfile(platform / "runtime.mjs", output / "runtime.mjs")
    shutil.copyfile(ADAPTER / "src" / "main.mjs", output / "main.mjs")
    print(f"Built {output}/", flush=True)


if __name__ == "__main__":
    main()
