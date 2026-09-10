#!/usr/bin/env python3
"""Open each already-built GUI example and require its rendering smoke result.

Run after the GUI semantic suite with --keep-output. A display and a compatible
graphics driver are required. CI runs --wayland inside Xvfb to supply a virtual
Wayland compositor with an input seat and software Vulkan.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

from build_gui import executable_name
from gui_suite import ROOT, examples

MARKER = "PASS: GPUI mounted, rendered, and checked "
COUNTER_ARGUMENTS = ("--host-smoke-click", "Increment", "--host-smoke-expect", "1")


def check(executable, arguments=(), environment=None):
    command = [str(executable.resolve()), "--host-smoke", *arguments]
    print("==> " + " ".join(command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=30,
                            env=environment)
    print(result.stdout + result.stderr, end="", flush=True)
    result.check_returncode()
    if MARKER not in result.stderr:
        raise ValueError(f"GUI process exited without confirming rendering: {executable}")


def run(directory, environment=None):
    for app in examples():
        arguments = COUNTER_ARGUMENTS if app.name == "counter" else ()
        check(directory / executable_name(app.name), arguments, environment)


def wayland(directory):
    drivers = Path("/usr/share/vulkan/icd.d")
    driver = next((path for path in (drivers / "lvp_icd.x86_64.json", drivers / "lvp_icd.json")
                   if path.is_file()), None)
    if driver is None:
        raise ValueError("install Mesa's software Vulkan driver before running virtual GUI smoke tests")
    with tempfile.TemporaryDirectory(prefix="signals-wayland-") as temporary:
        runtime = Path(temporary)
        environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime),
                           WAYLAND_DISPLAY="signals-smoke", VK_DRIVER_FILES=str(driver))
        environment.pop("ZED_HEADLESS", None)
        with (runtime / "weston.log").open("w+") as log:
            compositor = subprocess.Popen([
                "weston", "--backend=x11", "--renderer=pixman", "--shell=kiosk",
                "--socket=signals-smoke", "--idle-time=0", "--no-config",
            ], env=environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while not (runtime / "signals-smoke").is_socket():
                    if compositor.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("virtual Wayland compositor did not become ready")
                    time.sleep(0.1)
                run(directory, environment)
            finally:
                if compositor.poll() is None:
                    compositor.terminate()
                    try:
                        compositor.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        compositor.kill()
                        compositor.wait()
                log.seek(0)
                print(log.read(), end="", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / ".test-out/gui")
    parser.add_argument("--wayland", action="store_true", help="Run Weston on the supplied X display; use xvfb-run for CI")
    args = parser.parse_args()
    (wayland if args.wayland else run)(args.directory)
