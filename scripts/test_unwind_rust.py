#!/usr/bin/env python3
"""Exercise Rust panic recovery with an extracted LLVM unwinder candidate.

Rust supplies the test program and standard library, while pinned Zig supplies
headers and startup inputs. Explicit final linking excludes implicit unwinders.
This executable is validation evidence and is not part of the released payload.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

from build_glibc import verified_toolchain
from dependency_artifacts import unpack_verified

ROOT = Path(__file__).resolve().parents[1]


def run(candidate, cache):
    recipe = json.loads((ROOT / "dependencies/unwind.json").read_text())
    compiler_version = subprocess.check_output(["rustc", "+1.95.0", "--version"], text=True)
    if not compiler_version.startswith("rustc 1.95.0 "):
        raise ValueError("Rust panic probe requires Rust 1.95.0")
    toolchain = verified_toolchain(recipe["toolchain"], cache)
    with tempfile.TemporaryDirectory(prefix="signals-unwind-rust-") as temporary:
        work = Path(temporary)
        admitted = work / "candidate"
        unpack_verified(candidate, {"name": "unwind", "target": "x64glibc"}, admitted)
        with tarfile.open(toolchain) as archive:
            archive.extractall(work / "toolchain", filter="data")
        zig = str(work / "toolchain" / recipe["toolchain"]["directory"] / "zig")
        environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(work / "global"),
                           ZIG_LOCAL_CACHE_DIR=str(work / "local"))
        for name in ("ZIG_LIB_DIR", "ZIG_LIBC", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH", "LD_PRELOAD"):
            environment.pop(name, None)
        rust_archive = work / "rust-probe.a"
        subprocess.run(["rustc", "+1.95.0", "--crate-type=staticlib", "--edition=2024",
                        "-C", "panic=unwind", "-C", "opt-level=2",
                        str(ROOT / "test/dependencies/unwind.rs"), "-o", str(rust_archive)],
                       env=environment, check=True, timeout=180)
        compiler = [zig, "cc", *recipe["cc_args"]]
        # A self-contained C program generates private Zig startup/link inputs.
        seed = work / "seed.c"
        seed.write_text("int main(void) { return 0; }\n")
        subprocess.run([*compiler, str(seed), "-o", str(work / "seed")],
                       env=environment, check=True, timeout=180)
        main_object = work / "main.o"
        subprocess.run([*compiler, "-fno-stack-protector", "-c",
                        str(ROOT / "test/dependencies/unwind-rust.c"), "-o", str(main_object)],
                       env=environment, check=True, timeout=60)
        support = []
        for name in ("crt1.o", "libc_nonshared.a", "libm.so.6", "libc.so.6"):
            matches = list((work / "global/o").glob("*/" + name))
            if len(matches) != 1:
                raise ValueError(f"expected one freshly generated Rust probe support input {name}")
            support.append(str(matches[0]))
        executable = work / "rust-probe"
        command = [*compiler, "-nostdlib", str(main_object), str(rust_archive), *support,
                   str(admitted / "targets/x64glibc/libunwind.a"),
                   "-Wl,--entry,_start", "-o", str(executable)]
        subprocess.run(command, env=environment, check=True, timeout=60)
        result = subprocess.run([str(executable)], env=environment, check=True,
                                capture_output=True, text=True, timeout=15)
        if result.stdout.strip() != "PASS: Rust panic caught and destructor executed":
            raise ValueError("candidate failed Rust panic recovery or destructor execution")
        print(result.stdout, end="")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/roc-signals/sources")
    args = parser.parse_args()
    run(args.candidate.resolve(), args.cache.resolve())
