#!/usr/bin/env python3
"""Locate a Roc Signals checkout and run its benchmark artifact builder."""

from __future__ import annotations

import os
from pathlib import Path
import runpy


def signals_root() -> Path:
    """Resolve the source checkout for in-tree and copied adapter builds."""
    configured = os.environ.get("ROC_SIGNALS_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


builder = signals_root() / "scripts" / "build_js_framework_benchmark.py"
if not builder.is_file():
    raise SystemExit(
        "cannot locate scripts/build_js_framework_benchmark.py; "
        "set ROC_SIGNALS_ROOT to a Roc Signals checkout"
    )

os.environ["ROC_SIGNALS_ADAPTER_DIR"] = str(Path(__file__).resolve().parent)
runpy.run_path(str(builder), run_name="__main__")
