#!/usr/bin/env python3
"""Publish tested musl archives and their consumer lock from an explicit main run.

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
WORKFLOW = REPOSITORY + "/.github/workflows/dependencies.yml"


def prepare(directory, tag, environment):
    if (environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or environment.get("GITHUB_REF") != "refs/heads/main"
            or environment.get("GITHUB_REPOSITORY") != REPOSITORY):
        raise ValueError("dependency publication requires an explicit main dispatch in the producer repository")
    source = environment.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source) or not re.fullmatch(r"deps-musl-[0-9][A-Za-z0-9.-]*", tag):
        raise ValueError("invalid dependency release identity")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if head != source:
        raise ValueError("dependency release checkout differs from tested source")
    expected = {"musl-x64musl.tar", "musl-arm64musl.tar"}
    if {path.name for path in directory.glob("*.tar")} != expected:
        raise ValueError("dependency release must include both tested musl architectures")
    artifacts = {}
    with tempfile.TemporaryDirectory(prefix="signals-release-dependencies-") as temporary:
        for target in ("x64musl", "arm64musl"):
            archive = directory / f"musl-{target}.tar"
            entry = {
                "name": "musl", "target": target, "repository": REPOSITORY,
                "release": tag, "asset": archive.name,
                "sha256": sha256(archive), "size": archive.stat().st_size,
                "source_sha": source, "source_ref": "refs/heads/main",
                "signer_workflow": WORKFLOW,
            }
            verify_archive(archive, entry)
            manifest = unpack_verified(archive, entry, Path(temporary) / target)
            required = {f"targets/{target}/libc.a", f"targets/{target}/crt1.o", "licenses/musl/COPYRIGHT"}
            if set(manifest["files"]) != required:
                raise ValueError("musl release has an incomplete or unexpected file set")
            artifacts[f"musl-{target}"] = entry
    lock = directory / "dependencies.lock.json"
    with lock.open("x") as output:
        output.write(json.dumps({"schema_version": 1, "artifacts": artifacts}, indent=2) + "\n")
    read_lock(lock)
    return source, [directory / name for name in sorted(expected)] + [lock]


def publish(directory, tag):
    source, assets = prepare(directory, tag, os.environ)
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
        "Each archive contains its upstream revision, build recipe identity, exact file hashes, "
        "and musl copyright notices. Both architectures passed native linked tests and a second "
        "build comparison. GitHub build attestations bind the archive digests to the producer.\n\n"
        "Review and commit `dependencies.lock.json` in the consuming platform; "
        "use `scripts/dependency_artifacts.py` to verify and fetch it. "
        "This release contains no platform host or application code.\n"
    )
    subprocess.run(["gh", "release", "create", tag, *map(str, assets), "--repo", REPOSITORY,
                    "--target", source, "--latest=false", "--title", f"musl link inputs {tag}",
                    "--notes-file", str(notes)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    publish(args.directory, args.tag)
