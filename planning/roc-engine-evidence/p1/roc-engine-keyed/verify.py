#!/usr/bin/env python3
"""Verify the built platform-roc adapter (structure, keyed identity, allocation balance)."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from build import signals_root

adapter_root = Path(__file__).resolve().parent
output = Path(os.environ.get("ROC_ENGINE_OUT") or adapter_root / "dist")
subprocess.run(
    ["node", str(adapter_root / "test" / "verify_artifact.mjs"), str(output / "app.wasm")],
    check=True,
    cwd=signals_root(),
)
