#!/usr/bin/env python3
"""Open each already-built GUI example and require its rendering smoke result.

Run after the GUI semantic suite with --keep-output. A display and a compatible
graphics driver are required; CI supplies Xvfb and software Vulkan on Linux.
"""

import argparse
from pathlib import Path
import subprocess

from build_gui import executable_name
from gui_suite import ROOT, examples

MARKER = "PASS: GPUI mounted, rendered, and checked "


def check(executable, arguments=()):
    command = [str(executable.resolve()), "--smoke", *arguments]
    print("==> " + " ".join(command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=30)
    print(result.stdout + result.stderr, end="", flush=True)
    result.check_returncode()
    if MARKER not in result.stderr:
        raise ValueError(f"GUI process exited without confirming rendering: {executable}")


def run(directory):
    for app in examples():
        arguments = ("--smoke-click", "Increment", "--smoke-expect", "Count: 1") if app.name == "counter" else ()
        check(directory / executable_name(app.name), arguments)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / ".test-out/gui")
    run(parser.parse_args().directory)
