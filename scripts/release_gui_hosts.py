#!/usr/bin/env python3
"""Admit and publish native GUI hosts with their matching source companions."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from dependency_artifacts import sha256, unpack_verified, verify_archive, read_lock
from release_dependencies import REPOSITORY, publish_assets

POLICY = {"targets": ("x64glibc", "x64win"),
                 "files_by_target": {
                     "x64glibc": ("libsignals_gpui_host.a", "libengine.a"),
                     "arm64mac": ("libsignals_gpui_host.a", "libengine.a"),
                     "x64win": ("signals_gpui_host.lib", "engine.lib", "signals.res"),
                 },
                 "licenses": ("LICENSE", "LICENSE-GPUI", "NOTICE.md", "NOTICE.json", "third-party-notices.tar.xz"),
                 "workflow": "gui-hosts.yml",
                 "inventory_error": "host release must include both eligible hosts and their tested source companions",
                 "validation": "Each extracted host candidate passed native GUI application specs with the pinned Roc compiler."}


def prepare(directory, tag, environment, targets=None):
    kind = "gui-host"
    policy = POLICY
    if targets is not None and (not targets or len(set(targets)) != len(targets)
                                or not set(targets) <= set(policy["targets"])):
        raise ValueError("explicit targets must select eligible GUI host targets exactly once")
    selected = tuple(targets) if targets is not None else policy["targets"]
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
    expected = {f"{kind}-{target}.tar" for target in selected}
    expected.update(f"gui-host-sources-{target}.tar" for target in selected)
    if {path.name for path in directory.glob("*.tar")} != expected:
        raise ValueError(policy["inventory_error"])
    artifacts = {}
    with tempfile.TemporaryDirectory(prefix="signals-release-dependencies-") as temporary:
        for target in selected:
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
            names = policy["files_by_target"][target]
            required = {f"targets/{target}/{name}" for name in names}
            required.update(f"licenses/{kind}/{name}" for name in policy["licenses"])
            if set(manifest["files"]) != required:
                raise ValueError(f"{kind} release has an incomplete or unexpected file set")
            from gui_host_artifacts import source_fingerprint, validate_host, validate_publication_notices
            validate_host(Path(temporary) / target, target, source_fingerprint())
            source_archive = directory / f"gui-host-sources-{target}.tar"
            source_entry = dict(entry, name="gui-host-sources", asset=source_archive.name,
                                sha256=sha256(source_archive), size=source_archive.stat().st_size)
            notice = json.loads((Path(temporary) / target / "licenses/gui-host/NOTICE.json").read_text())
            if any(source_entry[k] != notice["source_companion"][k]
                   for k in ("name", "target", "asset", "sha256", "size")):
                raise ValueError("host release source companion differs from the tested notice binding")
            verify_archive(source_archive, source_entry)
            sources = Path(temporary) / (target + "-sources")
            unpack_verified(source_archive, source_entry, sources)
            validate_publication_notices(Path(temporary) / target, sources)
            artifacts[f"gui-host-sources-{target}"] = source_entry
            artifacts[f"{kind}-{target}"] = entry
    lock = directory / "dependencies.lock.json"
    with lock.open("x") as output:
        output.write(json.dumps({"schema_version": 1, "artifacts": artifacts}, indent=2) + "\n")
    read_lock(lock)
    return source, [directory / name for name in sorted(expected)] + [lock]


def publish(directory, tag, targets=None):
    source, assets = prepare(directory, tag, os.environ, targets)
    publish_assets(directory, tag, "gui-host", source, assets, POLICY["validation"],
                   "This release contains platform host code; external link dependencies are released separately.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--target", action="append", help="Eligible GUI host target (repeat to select several)")
    args = parser.parse_args()
    publish(args.directory, args.tag, args.target)
