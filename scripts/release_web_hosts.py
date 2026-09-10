#!/usr/bin/env python3
"""Publish one immutable dependency release containing all web platform hosts."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from dependency_artifacts import read_lock, sha256, unpack_verified, verify_archive
from release_dependencies import publish_assets
from web_host_artifacts import IDENTITIES, OUTPUTS, REPOSITORY, WORKFLOW, source_fingerprint, validate


def prepare(directory, tag, environment):
    if (environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or environment.get("GITHUB_REF") != "refs/heads/main"
            or environment.get("GITHUB_REPOSITORY") != REPOSITORY
            or not re.fullmatch(r"deps-web-hosts-[0-9][A-Za-z0-9.-]*", tag)):
        raise ValueError("web host publication requires a new explicit main release dispatch")
    source = environment.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source) or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True).strip() != source:
        raise ValueError("web host release checkout differs from the tested source")
    expected = {"web-host-" + target + ".tar" for target in OUTPUTS}
    if {path.name for path in directory.glob("*.tar")} != expected:
        raise ValueError("web host release must contain the complete five-target candidate set")
    fingerprint = source_fingerprint()
    artifacts = {}
    with tempfile.TemporaryDirectory(prefix="signals-release-web-hosts-") as temporary:
        for identity, target in zip(IDENTITIES, OUTPUTS):
            archive = directory / (identity + ".tar")
            entry = {"name": "web-host", "target": target, "repository": REPOSITORY,
                     "release": tag, "asset": archive.name, "sha256": sha256(archive),
                     "size": archive.stat().st_size, "source_sha": source,
                     "source_ref": "refs/heads/main", "signer_workflow": WORKFLOW,
                     "input_fingerprint": fingerprint}
            verify_archive(archive, entry)
            tree = Path(temporary) / identity
            unpack_verified(archive, entry, tree)
            validate(tree, target, fingerprint)
            artifacts[identity] = entry
    lock = directory / "dependencies.lock.json"
    lock.write_text(json.dumps({"schema_version": 1, "artifacts": artifacts}, indent=2) + "\n")
    read_lock(lock)
    return source, tuple(directory / name for name in sorted(expected)) + (lock,)


def publish(directory, tag):
    source, assets = prepare(directory, tag, os.environ)
    publish_assets(directory, tag, "web-hosts", source, assets,
                   "The complete prebuilt web native-spec and Wasm host set passed producer validation.",
                   "External musl linker inputs remain independently released dependencies.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    publish(args.directory, args.tag)
