#!/usr/bin/env python3
"""Build LLVM libunwind from a verified Zig distribution.

Only libunwind is published; C++ libraries generated for the exception probe
remain private test inputs. Original sources and notices accompany the archive.
"""

import argparse
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
from build_glibc import verified_toolchain

from dependency_archive import digest, write_archive
from dependency_artifacts import sha256, unpack_verified

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "dependencies/unwind.json"
PROBE = ROOT / "test/dependencies/unwind.cpp"
BUILDER = ROOT / "dependencies/unwind/Dockerfile"
LIBRARIES = {"libunwind.a": "libunwind.a"}

REPRODUCTION_FILES = (
    "dependencies/unwind.json",
    "dependencies/unwind/Dockerfile",
    "test/dependencies/unwind.cpp",
    "test/dependencies/unwind.rs",
    "test/dependencies/unwind-rust.c",
    "scripts/build_unwind.py",
    "scripts/build_glibc.py",
    "scripts/test_unwind_rust.py",
    "scripts/dependency_archive.py",
    "scripts/dependency_artifacts.py",
)


def corresponding_source(distribution):
    """Preserve source bytes and notices with normalized archive metadata.

    Include the complete bundled libunwind tree, retaining per-file notices.
    Zig's compiler is a separately pinned build tool.
    """
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:xz", format=tarfile.PAX_FORMAT) as archive:
        paths = [distribution / "LICENSE"]
        for name in ("lib/libunwind",):
            paths.extend(sorted((distribution / name).rglob("*")))
        for path in paths:
            if path.is_symlink():
                raise ValueError("unexpected link in bundled unwind sources")
            if not path.is_file():
                continue
            data = path.read_bytes()
            entry = tarfile.TarInfo(path.relative_to(distribution).as_posix())
            entry.size = len(data)
            entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(data))
    return stream.getvalue()


def inside_builder(output, toolchain, image_id):
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("unwind production requires native Linux x86_64")
    destination = output / "unwind-x64glibc.tar"
    if destination.exists():
        raise FileExistsError(destination)
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    if toolchain.stat().st_size != recipe["toolchain"]["size"] or sha256(toolchain) != recipe["toolchain"]["sha256"]:
        raise ValueError("Zig distribution differs from its reviewed pin")
    # /work is a new private tmpfs for each container, with stable debug paths.
    work = Path("/work")
    with tarfile.open(toolchain) as archive:
        archive.extractall(work / "toolchain", filter="data")
    distribution = work / "toolchain" / recipe["toolchain"]["directory"]
    zig = str(distribution / "zig")
    if subprocess.check_output([zig, "version"], text=True).strip() != recipe["zig_version"]:
        raise ValueError("unexpected Zig version")
    environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(work / "global"),
                       ZIG_LOCAL_CACHE_DIR=str(work / "local"))
    for name in ("ZIG_LIB_DIR", "ZIG_LIBC", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH", "LD_PRELOAD"):
        environment.pop(name, None)
    compiler = [zig, "c++", *recipe["cc_args"]]
    subprocess.run([*compiler, str(PROBE), "-o", str(work / "bootstrap")],
                   cwd=work, env=environment, check=True, timeout=600)
    inputs = work / "inputs"
    inputs.mkdir()
    for name, cached_name in LIBRARIES.items():
        matches = list((work / "global/o").glob("*/" + cached_name))
        if len(matches) != 1:
            raise ValueError(f"expected one freshly generated {cached_name}")
        shutil.copyfile(matches[0], inputs / name)
    files = {"targets/x64glibc/" + name: (inputs / name).read_bytes() for name in LIBRARIES}
    files.update({"licenses/unwind/LICENSE.TXT": (distribution / "lib/libunwind/LICENSE.TXT").read_bytes(),
                  "licenses/unwind/LICENSE-ZIG": (distribution / "LICENSE").read_bytes(),
                  "sources/unwind/source.tar.xz": corresponding_source(distribution)})
    for name in REPRODUCTION_FILES:
        files["sources/unwind/" + name] = (ROOT / name).read_bytes()
    archive = write_archive(work / "unwind-x64glibc.tar", {
        "schema_version": 1, "name": "unwind", "version": recipe["version"], "target": recipe["target"],
        "source": recipe["toolchain"], "build": {"builder_image": image_id,
        "builder_recipe_sha256": sha256(BUILDER), "recipe_sha256": digest(recipe_bytes),
        "producer_sha256": sha256(Path(__file__)), "probe_sha256": sha256(PROBE),
        "cc_args": recipe["cc_args"], "zig_version": recipe["zig_version"]},
    }, files)
    admitted = work / "candidate"
    unpack_verified(archive, {"name": "unwind", "target": "x64glibc"}, admitted)
    linked = admitted / "targets/x64glibc"
    executable = work / "candidate-probe"
    probe_object = work / "probe.o"
    # Disable all implicit libraries at final link: the tested unwinder
    # must be the extracted candidate, never another cached/system copy.
    subprocess.run([*compiler, "-fno-stack-protector", "-c", str(PROBE), "-o", str(probe_object)],
                   cwd=work, env=environment, check=True, timeout=60)
    support = []
    for name in ("crt1.o", "libc++.a", "libc++abi.a", "libc_nonshared.a", "libm.so.6", "libc.so.6"):
        matches = list((work / "global/o").glob("*/" + name))
        if len(matches) != 1:
            raise ValueError(f"expected one freshly generated probe support input {name}")
        support.append(str(matches[0]))
    subprocess.run([zig, "cc", *recipe["cc_args"], "-nostdlib", str(probe_object),
                    *support, str(linked / "libunwind.a"),
                    "-Wl,--entry,_start", "-o", str(executable)],
                   cwd=work, env=environment, check=True, timeout=60)
    result = subprocess.run([str(executable)], env=environment, check=True,
                            capture_output=True, text=True, timeout=15)
    if result.stdout.strip() != "PASS: C++ exception unwinding":
        raise ValueError("unwind candidate did not confirm exception handling and destruction")
    print(result.stdout, end="")
    output.mkdir(parents=True, exist_ok=True)
    with archive.open("rb") as source, destination.open("xb") as target:
        # Publication happens only after the extracted candidate passes.
        shutil.copyfileobj(source, target)
    return destination


def build(output, cache):
    """Build in a pinned, offline container and publish only a tested candidate."""
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("unwind production requires native Linux x86_64 and Docker")
    destination = output / "unwind-x64glibc.tar"
    if destination.exists():
        raise FileExistsError(destination)
    recipe = json.loads(RECIPE.read_bytes())
    toolchain = verified_toolchain(recipe["toolchain"], cache)
    tag = "signals-unwind-builder:" + sha256(BUILDER)[:24]
    subprocess.run(["docker", "build", "--platform=linux/amd64", "--tag", tag, str(BUILDER.parent)],
                   check=True, timeout=1800)
    image_id = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", tag], text=True).strip()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix=".unwind-") as temporary:
        stage = Path(temporary)
        subprocess.run([
            "docker", "run", "--platform=linux/amd64", "--rm", "--network=none", "--read-only",
            "--cap-drop=ALL", "--security-opt=no-new-privileges", "--user", f"{os.getuid()}:{os.getgid()}",
            "--tmpfs", "/work:exec,mode=1777", "--tmpfs", "/tmp:exec,mode=1777",
            "--env", "PYTHONDONTWRITEBYTECODE=1", "--workdir", "/work",
            "--volume", str(ROOT / "scripts") + ":/repo/scripts:ro",
            "--volume", str(ROOT / "dependencies") + ":/repo/dependencies:ro",
            "--volume", str(ROOT / "test/dependencies") + ":/repo/test/dependencies:ro",
            "--volume", str(toolchain) + ":/source.tar.xz:ro", "--volume", str(stage) + ":/output",
            image_id, "python3", "/repo/scripts/build_unwind.py", "--inside", "--image-id", image_id,
            "--output", "/output",
        ], check=True, timeout=1200)
        os.link(stage / destination.name, destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/roc-signals/sources")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--image-id", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        print(inside_builder(args.output, Path("/source.tar.xz"), args.image_id))
    else:
        print(build(args.output.resolve(), args.cache.resolve()))
