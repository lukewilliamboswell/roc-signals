#!/usr/bin/env python3
"""Build independently releasable musl link inputs from a reviewed source pin.

This producer never reads platform target directories or the platform host.
Consumers download the resulting release; ordinary host builds do not run it.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "dependencies/musl.json"


def run(arguments, **kwargs):
    subprocess.run(arguments, check=True, **kwargs)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(target, output, jobs):
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    triple = recipe["targets"][target]
    zig_version = subprocess.check_output(["zig", "version"], text=True).strip()
    if zig_version != recipe["zig_version"]:
        raise ValueError(f"musl producer needs Zig {recipe['zig_version']}, got {zig_version}")
    if jobs < 1:
        raise ValueError("jobs must be positive")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"musl-{target}.tar"
    if archive.exists():
        raise ValueError(f"refusing to replace an existing artifact: {archive}")
    with tempfile.TemporaryDirectory(prefix="signals-musl-") as temporary:
        work = Path(temporary)
        source = work / "source"
        run(["git", "init", "--quiet", str(source)])
        run(["git", "-C", str(source), "fetch", "--depth=1", recipe["repository"], recipe["revision"]])
        run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        if revision != recipe["revision"]:
            raise ValueError("musl checkout differs from its source pin")
        build_dir = work / "build"
        build_dir.mkdir()
        # Disable compiler-inserted runtime dependencies when compiling libc itself.
        # Baseline CPUs keep the release usable beyond the producer's own CPU.
        cc = f"zig cc -target {triple} -mcpu=baseline -fno-sanitize=all"
        environment = dict(os.environ, CC=cc, AR="zig ar", RANLIB="zig ranlib", LC_ALL="C",
                           CFLAGS=f"-ffile-prefix-map={work}=/build")
        configure = [str(source / "configure"), "--disable-shared", "--prefix=/usr"]
        run(configure, cwd=build_dir, env=environment)
        run(["make", f"-j{jobs}", "lib/libc.a", "lib/crt1.o"], cwd=build_dir, env=environment)
        files = {f"targets/{target}/{name}": (build_dir / "lib" / name).read_bytes()
                 for name in ("libc.a", "crt1.o")}
        files["licenses/musl/COPYRIGHT"] = (source / "COPYRIGHT").read_bytes()
        manifest = {
            "schema_version": 1,
            "name": "musl",
            "version": recipe["version"],
            "target": target,
            "source": {"repository": recipe["repository"], "revision": revision},
            "build": {"zig_version": zig_version, "cc": cc,
                      "configure": configure[1:], "cflags": "-ffile-prefix-map=<work>=/build",
                      "recipe_sha256": digest(recipe_bytes),
                      "producer_sha256": digest(Path(__file__).read_bytes())},
            "files": {name: {"sha256": digest(data), "size": len(data)}
                      for name, data in sorted(files.items())},
        }
        files["dependency.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
        # File order, metadata, permissions, and timestamps are canonical. Publication
        # occurs only after the complete archive is closed successfully.
        staged = work / archive.name
        with tarfile.open(staged, "w", format=tarfile.USTAR_FORMAT) as packed:
            for name, data in sorted(files.items()):
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                entry.mode = 0o644
                packed.addfile(entry, io.BytesIO(data))
        # Copy to a private file on the destination filesystem before publication.
        with tempfile.NamedTemporaryFile(dir=output, delete=False) as pending:
            pending_path = Path(pending.name)
            try:
                with staged.open("rb") as built:
                    shutil.copyfileobj(built, pending)
            except BaseException:
                pending_path.unlink(missing_ok=True)
                raise
        try:
            os.link(pending_path, archive)
        finally:
            pending_path.unlink(missing_ok=True)
    print(f"{digest(archive.read_bytes())}  {archive.name}")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(json.loads(RECIPE.read_text())["targets"]), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    build(args.target, args.output.resolve(), args.jobs)
