#!/usr/bin/env python3
"""Verify a built adapter using the owning Roc Signals checkout."""

from __future__ import annotations

import subprocess
from pathlib import Path

from build import signals_root


adapter_root = Path(__file__).resolve().parent
verifier = signals_root() / "scripts" / "browser" / "verify_js_framework_artifact.mjs"
if not verifier.is_file():
    raise SystemExit(
        "cannot locate scripts/browser/verify_js_framework_artifact.mjs; "
        "set ROC_SIGNALS_ROOT to a Roc Signals checkout"
    )

subprocess.run(
    ["node", str(verifier), str(adapter_root / "dist" / "app.wasm")],
    check=True,
)
