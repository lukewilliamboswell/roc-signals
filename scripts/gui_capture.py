#!/usr/bin/env python3
"""Capture one GUI example's own window at a requested size.

Screenshots are review evidence, so this deliberately names a single window
rather than grabbing a screen region: a region capture would include whatever
else the reviewer's desktop had in front, which is both unusable as evidence
and not ours to publish. The window size comes from the host's --host-window-size
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


def window(helper: Path, pid: int, deadline: float) -> tuple[str, int, int]:
    """Waits for the application's window to appear and settle at its final size.

    A window measured while it is still opening reports an intermediate size, so
    the reading is only trusted once it repeats: a capture whose recorded size
    does not match the size it was asked for is not usable as evidence.
    """
    previous = None
    while True:
        found = subprocess.run([str(helper), str(pid)], capture_output=True, text=True)
        if found.returncode == 0:
            identifier, width, height = found.stdout.split()
            current = (identifier, int(width), int(height))
            if current == previous:
                return current
            previous = current
        elif time.monotonic() >= deadline:
            raise SystemExit(f"process {pid} never opened a window: {found.stderr.strip()}")
        if time.monotonic() >= deadline:
            raise SystemExit(f"process {pid} never settled at one window size")
        time.sleep(0.2)


def capture(executable: Path, destination: Path, size: str | None, settle: float,
            arguments=(), environment=None, timeout: float = 30.0, ready=None) -> Path:
    """Runs one application, captures its window, and stops it again.

    ``ready`` lets a caller photograph a state the application reaches after
    startup: the capture waits for it to return true before settling. A driven
    application is normally still running when it becomes ready, so the wait is
    bounded by the same deadline as the window itself.

    ``size`` is the ``--host-window-size`` to request. When it is ``None`` the
    application sizes its own window — a scenario's header does — and ``ready``
    must then return the ``WIDTHxHEIGHT`` the run reported, so the capture is
    still refused when the window does not match what was asked for.
    """
    helper = locator()
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [str(executable.resolve()), *arguments]
    if size is not None:
        command[1:1] = ["--host-window-size", size]
    print("==> " + " ".join(command), flush=True)
    application = subprocess.Popen(command, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + timeout
        identifier, width, height = window(helper, application.pid, deadline)
        reported = None
        while ready is not None and not (reported := ready()):
            if time.monotonic() >= deadline:
                raise SystemExit(f"{executable.name} never reached the state to capture")
            time.sleep(0.2)
        if size is None:
            if not isinstance(reported, str):
                raise SystemExit("a capture without --host-window-size needs the run to report its size")
            size = reported
        requested = tuple(int(part) for part in size.lower().split("x"))
        # The recorded window frame includes the titlebar and can differ from the
        # requested content size by a few points of client decoration, but a
        # capture that silently came back at another size is not evidence.
        if abs(width - requested[0]) > 32 or abs(height - requested[1]) > 64:
            raise SystemExit(
                f"captured a {width}x{height} window after requesting {size}; "
                "the application did not honour --host-window-size")
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
    extra = ("--host-assets-root", str(arguments.assets_root)) if arguments.assets_root else ()
    capture(arguments.executable, arguments.destination, arguments.size,
            arguments.settle, extra, dict(os.environ))


if __name__ == "__main__":
    main()
