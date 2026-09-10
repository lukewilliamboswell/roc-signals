#!/usr/bin/env python3
"""Capture one GUI example's own window at a requested size.

Screenshots are review evidence, so this deliberately names a single window
rather than grabbing a screen region: a region capture would include whatever
else the reviewer's desktop had in front, which is both unusable as evidence
and not ours to publish. The window size comes from the host's --window-size
flag because resizing another process's window needs desktop automation
permissions that are not available on every supported system.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
LOCATOR_SOURCE = ROOT / "scripts/mac_window_id.swift"


def locator() -> Path:
    """Builds, and caches, the helper that maps a process name to its window."""
    if sys.platform != "darwin":
        raise SystemExit("window captures are currently implemented for macOS only")
    if shutil.which("swiftc") is None:
        raise SystemExit("install the Xcode command line tools to capture GUI windows")
    built = ROOT / "zig-out/gui-capture/mac_window_id"
    if not built.is_file() or built.stat().st_mtime < LOCATOR_SOURCE.stat().st_mtime:
        built.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(built), str(LOCATOR_SOURCE)], check=True)
    return built


def window(helper: Path, owner: str, deadline: float) -> tuple[str, int, int]:
    """Waits for the application's window, returning its id and captured size."""
    while True:
        found = subprocess.run([str(helper), owner], capture_output=True, text=True)
        if found.returncode == 0:
            identifier, width, height = found.stdout.split()
            return identifier, int(width), int(height)
        if time.monotonic() >= deadline:
            raise SystemExit(f"{owner} never opened a window: {found.stderr.strip()}")
        time.sleep(0.2)


def capture(executable: Path, destination: Path, size: str, settle: float,
            arguments=(), environment=None, timeout: float = 30.0) -> Path:
    """Runs one application, captures its window, and stops it again."""
    helper = locator()
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [str(executable.resolve()), "--window-size", size, *arguments]
    print("==> " + " ".join(command), flush=True)
    application = subprocess.Popen(command, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        identifier, width, height = window(helper, executable.stem, time.monotonic() + timeout)
        time.sleep(settle)
        subprocess.run(["screencapture", "-x", "-o", "-t", "png", f"-l{identifier}",
                        str(destination)], check=True)
    finally:
        application.terminate()
        try:
            application.wait(timeout=5)
        except subprocess.TimeoutExpired:
            application.kill()
    if not destination.is_file() or destination.stat().st_size == 0:
        raise SystemExit(f"capture produced no image: {destination}")
    print(f"    {destination} ({width}x{height} window)", flush=True)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="A built GUI example")
    parser.add_argument("destination", type=Path, help="PNG path to write")
    parser.add_argument("--size", default="1200x820", help="Window content size, WIDTHxHEIGHT")
    parser.add_argument("--settle", type=float, default=1.5,
                        help="Seconds to let the first frame and any startup work finish")
    parser.add_argument("--assets-root", type=Path, help="Asset directory for the example")
    arguments = parser.parse_args()
    extra = ("--assets-root", str(arguments.assets_root)) if arguments.assets_root else ()
    capture(arguments.executable, arguments.destination, arguments.size,
            arguments.settle, extra, dict(os.environ))


if __name__ == "__main__":
    main()
