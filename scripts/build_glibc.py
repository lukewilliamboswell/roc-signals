#!/usr/bin/env python3
"""Generate glibc startup and link stubs using a verified Zig distribution.

The operating system supplies glibc's runtime implementation. Each candidate
also carries the bundled source/headers, license texts, and reproduction recipe.
No platform host, system development library, or shared compiler cache is used.
"""

import argparse
from contextlib import nullcontext
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen

from dependency_archive import digest, write_archive
from dependency_artifacts import sha256, unpack_verified

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "dependencies/glibc.json"
PROBE = ROOT / "test/dependencies/glibc.c"
BUILDER = ROOT / "dependencies/glibc/Dockerfile"
LIBRARIES = {"crt1.o": "crt1.o", "libc.so": "libc.so.6", "libm.so": "libm.so.6",
             "libc_nonshared.a": "libc_nonshared.a"}


def verified_toolchain(source, cache):
    """Download bounded bytes and verify the distribution again on cache hits."""
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / (source["sha256"] + ".tar.xz")
    if not destination.exists():
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
            pending = Path(temporary.name)
        try:
            with urlopen(source["url"], timeout=60) as response, pending.open("wb") as output:
                remaining = source["size"]
                while remaining:
                    chunk = response.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ValueError("truncated Zig distribution")
                    output.write(chunk)
                    remaining -= len(chunk)
                if response.read(1):
                    raise ValueError("oversized Zig distribution")
            if sha256(pending) != source["sha256"]:
                raise ValueError("Zig distribution differs from its reviewed pin")
            try:
                os.link(pending, destination)
            except FileExistsError:
                pass
        finally:
            pending.unlink(missing_ok=True)
    if destination.is_symlink() or destination.stat().st_size != source["size"] or sha256(destination) != source["sha256"]:
        raise ValueError("Zig distribution differs from its reviewed pin")
    return destination


def corresponding_source(distribution):
    """Preserve source bytes and notices with normalized archive metadata.

    Include all glibc sources and C headers rather than inferring a minimum
    include closure. Zig's compiler is a separately pinned build tool.
    """
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:xz", format=tarfile.PAX_FORMAT) as archive:
        paths = [distribution / "LICENSE"]
        for name in ("lib/libc/glibc", "lib/libc/include", "lib/include"):
            paths.extend(sorted((distribution / name).rglob("*")))
        for path in paths:
            if path.is_symlink():
                raise ValueError("unexpected link in bundled glibc sources")
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
        raise ValueError("glibc production requires native Linux x86_64")
    destination = output / "glibc-x64glibc.tar"
    if destination.exists():
        raise FileExistsError(destination)
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    license_text = (ROOT / "dependencies/glibc/COPYING.LIB").read_bytes()
    if digest(license_text) != recipe["license"]["sha256"]:
        raise ValueError("glibc license differs from the reviewed pin")
    if toolchain.stat().st_size != recipe["toolchain"]["size"] or sha256(toolchain) != recipe["toolchain"]["sha256"]:
        raise ValueError("Zig distribution differs from its reviewed pin")
    # /work is a new private tmpfs for each container, with stable debug paths.
    with nullcontext(Path("/work")) as work:
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
        compiler = [zig, "cc", *recipe["cc_args"]]
        subprocess.run([*compiler, str(PROBE), "-o", str(work / "bootstrap")],
                       cwd=work, env=environment, check=True, timeout=180)
        inputs = work / "inputs"
        inputs.mkdir()
        for name, cached_name in LIBRARIES.items():
            matches = list((work / "global/o").glob("*/" + cached_name))
            if len(matches) != 1:
                raise ValueError(f"expected one freshly generated {cached_name}")
            shutil.copyfile(matches[0], inputs / name)
        files = {"targets/x64glibc/" + name: (inputs / name).read_bytes() for name in LIBRARIES}
        files.update({"licenses/glibc/COPYING.LIB": license_text,
                      "licenses/glibc/LICENSES": (distribution / "lib/libc/glibc/LICENSES").read_bytes(),
                      "licenses/glibc/LICENSE-ZIG": (distribution / "LICENSE").read_bytes(),
                      "sources/glibc/source.tar.xz": corresponding_source(distribution),
                      "sources/glibc/dependencies/glibc.json": recipe_bytes,
                      "sources/glibc/dependencies/glibc/COPYING.LIB": license_text,
                      "sources/glibc/dependencies/glibc/Dockerfile": BUILDER.read_bytes(),
                      "sources/glibc/test/dependencies/glibc.c": PROBE.read_bytes(),
                      "sources/glibc/scripts/build_glibc.py": Path(__file__).read_bytes(),
                      "sources/glibc/scripts/dependency_archive.py": (ROOT / "scripts/dependency_archive.py").read_bytes(),
                      "sources/glibc/scripts/dependency_artifacts.py": (ROOT / "scripts/dependency_artifacts.py").read_bytes()})
        archive = write_archive(work / "glibc-x64glibc.tar", {
            "schema_version": 1, "name": "glibc", "version": recipe["version"], "target": recipe["target"],
            "source": recipe["toolchain"], "build": {"builder_image": image_id,
            "builder_recipe_sha256": sha256(BUILDER), "recipe_sha256": digest(recipe_bytes),
            "producer_sha256": sha256(Path(__file__)), "probe_sha256": sha256(PROBE),
            "cc_args": recipe["cc_args"], "zig_version": recipe["zig_version"]},
        }, files)
        admitted = work / "candidate"
        unpack_verified(archive, {"name": "glibc", "target": "x64glibc"}, admitted)
        linked = admitted / "targets/x64glibc"
        executable = work / "candidate-probe"
        probe_object = work / "probe.o"
        # Compile with the pinned headers, then disable implicit inputs only at
        # the link step. Zig's -nostdlib also disables its libc header search.
        subprocess.run([*compiler, "-fno-stack-protector", "-c", str(PROBE), "-o", str(probe_object)],
                       cwd=work, env=environment, check=True, timeout=60)
        subprocess.run([*compiler, "-nostdlib", str(probe_object),
                        str(linked / "crt1.o"), str(linked / "libc_nonshared.a"),
                        str(linked / "libm.so"), str(linked / "libc.so"),
                        "-Wl,--entry,_start", "-o", str(executable)],
                       cwd=work, env=environment, check=True, timeout=60)
        result = subprocess.run([str(executable)], env=environment, check=True,
                                capture_output=True, text=True, timeout=15)
        if result.stdout.strip() != "PASS: generated glibc startup and link inputs":
            raise ValueError("glibc candidate did not confirm startup and termination")
        print(result.stdout, end="")
        output.mkdir(parents=True, exist_ok=True)
        with archive.open("rb") as source, destination.open("xb") as target:
            # Publication happens only after the extracted candidate passes.
            shutil.copyfileobj(source, target)
    return destination


def build(output, cache):
    """Build in a pinned, offline container and publish only a tested candidate."""
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("glibc production requires native Linux x86_64 and Docker")
    destination = output / "glibc-x64glibc.tar"
    if destination.exists():
        raise FileExistsError(destination)
    recipe = json.loads(RECIPE.read_bytes())
    toolchain = verified_toolchain(recipe["toolchain"], cache)
    tag = "signals-glibc-builder:" + sha256(BUILDER)[:24]
    subprocess.run(["docker", "build", "--platform=linux/amd64", "--tag", tag, str(BUILDER.parent)],
                   check=True, timeout=1800)
    image_id = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", tag], text=True).strip()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix=".glibc-") as temporary:
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
            image_id, "python3", "/repo/scripts/build_glibc.py", "--inside", "--image-id", image_id,
            "--output", "/output",
        ], check=True, timeout=600)
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
