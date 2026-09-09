#!/usr/bin/env python3
"""Publish tested dependency archives and their consumer lock from an explicit main run.

Existing releases or tags are never replaced. A partially completed publication
requires inspection and recovery of the same tested bytes, not another build.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from dependency_artifacts import sha256, unpack_verified, verify_archive, read_lock

REPOSITORY = "lukewilliamboswell/roc-signals"
KINDS = {
    "unwind": {"targets": ("x64glibc",), "files": ("libunwind.a",),
               "licenses": ("LICENSE.TXT", "LICENSE-ZIG"),
               "extra_files": tuple("sources/unwind/" + name for name in (
                   "source.tar.xz",
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
               )),
               "workflow": "unwind-dependencies.yml",
               "inventory_error": "dependency release must include the tested LLVM unwinder",
               "validation": "The extracted candidate passed C++ exception handling and Rust panic recovery with destructor tests; two clean builds produced identical archives. Original sources and reproduction inputs accompany the library."},
    "glibc": {"targets": ("x64glibc",), "files": ("crt1.o", "libc.so", "libm.so", "libc_nonshared.a"),
              "licenses": ("COPYING.LIB", "LICENSES", "LICENSE-ZIG"),
              "extra_files": tuple("sources/glibc/" + name for name in (
                  "source.tar.xz", "dependencies/glibc.json", "dependencies/glibc/COPYING.LIB",
                  "dependencies/glibc/Dockerfile", "test/dependencies/glibc.c",
                  "scripts/build_glibc.py", "scripts/dependency_archive.py", "scripts/dependency_artifacts.py")),
              "workflow": "glibc-dependencies.yml",
              "inventory_error": "dependency release must include the tested glibc link inputs",
              "validation": "The extracted candidate passed startup, termination, math, allocation, and thread tests; two clean builds produced identical archives. Corresponding bundled sources and reproduction inputs accompany the binaries."},
    "xkbcommon": {"targets": ("x64glibc",), "files": ("libxkbcommon.so", "libxkbcommon-x11.so"),
                  "licenses": ("LICENSE",), "workflow": "xkbcommon-dependencies.yml",
                  "inventory_error": "dependency release must include both tested xkbcommon libraries",
                  "validation": "The extracted candidate parsed and translated a self-contained keyboard map, and two clean builds produced identical archives."},
    "musl": {"targets": ("x64musl", "arm64musl"), "files": ("libc.a", "crt1.o"),
             "licenses": ("COPYRIGHT",), "workflow": "dependencies.yml",
             "inventory_error": "dependency release must include both tested musl architectures",
             "validation": "Both architectures passed native linked tests and a second build comparison."},
    "windows-imports": {"targets": ("x64win",), "files": ("advapi32.lib",),
                        "licenses": ("COPYING",), "workflow": "windows-dependencies.yml",
                        "inventory_error": "dependency release must include the tested Windows import archive",
                        "validation": "The candidate passed a native Windows DLL import probe and a second build comparison."},
    "freetype": {"targets": ("x64glibc",), "files": ("libfreetype.so",),
                 "licenses": ("LICENSE.TXT", "FTL.TXT", "GPLv2.TXT", "NOTICE"),
                 "workflow": "freetype-dependencies.yml",
                 "inventory_error": "dependency release must include the tested FreeType archive",
                 "validation": "The extracted candidate rendered the expected glyph bitmap, and two clean container builds produced identical archives."},
}


def prepare(directory, tag, environment, kind="musl"):
    policy = KINDS[kind]
    if (environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or environment.get("GITHUB_REF") != "refs/heads/main"
            or environment.get("GITHUB_REPOSITORY") != REPOSITORY):
        raise ValueError("dependency publication requires an explicit main dispatch in the producer repository")
    source = environment.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source) or not re.fullmatch(rf"deps-{kind}-[0-9][A-Za-z0-9.-]*", tag):
        raise ValueError("invalid dependency release identity")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if head != source:
        raise ValueError("dependency release checkout differs from tested source")
    expected = {f"{kind}-{target}.tar" for target in policy["targets"]}
    if {path.name for path in directory.glob("*.tar")} != expected:
        raise ValueError(policy["inventory_error"])
    artifacts = {}
    with tempfile.TemporaryDirectory(prefix="signals-release-dependencies-") as temporary:
        for target in policy["targets"]:
            archive = directory / f"{kind}-{target}.tar"
            entry = {
                "name": kind, "target": target, "repository": REPOSITORY,
                "release": tag, "asset": archive.name,
                "sha256": sha256(archive), "size": archive.stat().st_size,
                "source_sha": source, "source_ref": "refs/heads/main",
                "signer_workflow": REPOSITORY + "/.github/workflows/" + policy["workflow"],
            }
            verify_archive(archive, entry)
            manifest = unpack_verified(archive, entry, Path(temporary) / target)
            required = {f"targets/{target}/{name}" for name in policy["files"]}
            required.update(f"licenses/{kind}/{name}" for name in policy["licenses"])
            required.update(policy.get("extra_files", ()))
            if set(manifest["files"]) != required:
                raise ValueError(f"{kind} release has an incomplete or unexpected file set")
            artifacts[f"{kind}-{target}"] = entry
    lock = directory / "dependencies.lock.json"
    with lock.open("x") as output:
        output.write(json.dumps({"schema_version": 1, "artifacts": artifacts}, indent=2) + "\n")
    read_lock(lock)
    return source, [directory / name for name in sorted(expected)] + [lock]


def publish(directory, tag, kind="musl"):
    source, assets = prepare(directory, tag, os.environ, kind)
    # The CLI refuses an existing release. Check tags too: --target alone does
    # not require a pre-existing tag to refer to the tested source.
    tags = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}",
    ], text=True))
    if any(item["ref"] == "refs/tags/" + tag for item in tags):
        raise ValueError("dependency tag already exists; inspect and recover the original publication")
    notes = directory / "release-notes.md"
    notes.write_text(
        f"Dependency inputs built and tested from platform repository commit `{source}`.\n\n"
        "Each archive contains its upstream source identity, build recipe identity, exact file hashes, "
        "and copyright notices. " + KINDS[kind]["validation"] + " "
        "GitHub build attestations bind the archive digests to the producer.\n\n"
        "Review and commit `dependencies.lock.json` in the consuming platform; "
        "use `scripts/dependency_artifacts.py` to verify and fetch it. "
        "This release contains no platform host or application code.\n"
    )
    subprocess.run(["gh", "release", "create", tag, *map(str, assets), "--repo", REPOSITORY,
                    "--target", source, "--latest=false", "--title", f"{kind} link inputs {tag}",
                    "--notes-file", str(notes)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--kind", choices=sorted(KINDS), default="musl")
    args = parser.parse_args()
    publish(args.directory, args.tag, args.kind)
