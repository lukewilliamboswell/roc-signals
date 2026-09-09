#!/usr/bin/env python3
"""Validate and execute a candidate musl archive without using checkout binaries.

This is a producer-side test, before signing. Release consumers must additionally
verify signed provenance through dependency_artifacts before admitting an archive.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from dependency_artifacts import unpack_verified

ROOT = Path(__file__).resolve().parents[1]


def check(archive, target):
    recipe = json.loads((ROOT / "dependencies/musl.json").read_text())
    triple = recipe["targets"][target]
    with tempfile.TemporaryDirectory(prefix="signals-musl-test-") as temporary:
        work = Path(temporary)
        unpack_verified(archive, {"name": "musl", "target": target}, work / "input")
        inputs = work / "input/targets" / target
        obj = work / "smoke.o"
        binary = work / "smoke"
        subprocess.run(["zig", "cc", "-target", triple, "-mcpu=baseline", "-O2",
                        "-c", str(ROOT / "test/dependencies/musl.c"), "-o", str(obj)], check=True)
        subprocess.run(["zig", "cc", "-target", triple, "-nostdlib", "-static",
                        str(inputs / "crt1.o"), str(obj), str(inputs / "libc.a"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--target", choices=["x64musl", "arm64musl"], required=True)
    args = parser.parse_args()
    check(args.archive, args.target)
