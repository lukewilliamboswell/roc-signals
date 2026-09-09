#!/usr/bin/env python3
"""Link a Windows probe exclusively against a producer candidate import library.

This is producer-side validation before signing. Consumers must use the locked
provenance verifier instead. Native Windows runs additionally execute the probe.
"""

import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

from dependency_artifacts import unpack_verified

ROOT = Path(__file__).resolve().parents[1]


def check(archive):
    with tempfile.TemporaryDirectory(prefix="signals-import-probe-") as temporary:
        work = Path(temporary)
        inputs = work / "inputs"
        manifest = unpack_verified(archive, {"name": "windows-imports", "target": "x64win"}, inputs)
        if set(manifest["files"]) != {"targets/x64win/advapi32.lib", "licenses/windows-imports/COPYING"}:
            raise ValueError("unexpected Windows import artifact inventory")
        executable = work / "probe.exe"
        subprocess.run([
            "zig", "cc", "-target", "x86_64-windows-gnu", "-nostdlib",
            "-fno-stack-protector", "-fno-sanitize=all", "-Wl,--entry,mainCRTStartup",
            str(ROOT / "test/dependencies/windows_imports.c"),
            str(inputs / "targets/x64win/advapi32.lib"), "-lkernel32", "-o", str(executable),
        ], check=True)
        if platform.system() == "Windows":
            subprocess.run([str(executable)], check=True, timeout=15)
        else:
            print("Windows probe linked; native execution requires the Windows producer job")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    check(parser.parse_args().archive.resolve())
