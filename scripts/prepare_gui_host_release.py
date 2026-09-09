"""Compose and test a native host with its exact notices and source companion."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import urllib.request

from gui_host_artifacts import ROOT, HOST_FILES, check_candidate, pack_host, source_fingerprint
from host_notice_payload import compose, validate_packaged_outputs
import rust_license_inventory
import toolchain_license_inventory
from cargo_build_evidence import same_checkout_lock


def verified_download(url, checksum, destination, size=None):
    """Verify cached inputs and atomically retain only complete pinned downloads."""
    limit = size if size is not None else 512 * 1024 ** 2
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_file():
            raise ValueError("invalid cached host notice input")
        with destination.open("rb") as source:
            if ((size is not None and destination.stat().st_size != size)
                    or hashlib.file_digest(source, "sha256").hexdigest() != checksum):
                raise ValueError("cached host notice input differs from its pin")
        return destination
    if not url.startswith("https://"):
        raise ValueError("host notice downloads require HTTPS")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as pending:
        temporary = Path(pending.name)
    try:
        digest = hashlib.sha256()
        total = 0
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
            while data := response.read(min(1024 ** 2, limit - total + 1)):
                total += len(data)
                if total > limit:
                    raise ValueError("host notice download exceeds its size limit")
                digest.update(data)
                output.write(data)
        if (size is not None and total != size) or digest.hexdigest() != checksum:
            raise ValueError("host notice download differs from its pin")
        os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def crate_cache(evidence, cache):
    """Reuse verified Cargo archives or fetch their exact locked source bytes."""
    destination = cache / "crates"
    destination.mkdir(parents=True, exist_ok=True)
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    for package in evidence["packages"]:
        if package["source"] is None:
            continue
        if (package["source"] != rust_license_inventory.REGISTRY
                or not re.fullmatch(r"[A-Za-z0-9_-]+", package["name"])
                or not re.fullmatch(r"[A-Za-z0-9_.+-]+", package["version"])):
            raise ValueError("host source selection requires a supported locked crate")
        filename = package["name"] + "-" + package["version"] + ".crate"
        output = destination / filename
        if not output.exists() and not output.is_symlink():
            cached = list((cargo_home / "registry/cache").glob("*/" + filename))
            if cached:
                source = cached[0]
                if source.is_symlink() or not source.is_file():
                    raise ValueError("invalid Cargo source cache entry")
                data = source.read_bytes()
                if hashlib.sha256(data).hexdigest() != package["crate_sha256"]:
                    raise ValueError("Cargo source cache differs from Cargo.lock")
                with tempfile.NamedTemporaryFile(dir=destination, delete=False) as retained:
                    temporary = Path(retained.name)
                    retained.write(data)
                try:
                    os.link(temporary, output)
                finally:
                    temporary.unlink(missing_ok=True)
        verified_download(f"https://static.crates.io/crates/{package['name']}/{filename}",
                          package["crate_sha256"], output)
    return destination


def prepare(target, source, evidence_root, output, cache, roc, root=ROOT):
    """Publish a local candidate directory only after extracted native tests pass."""
    if output.exists():
        raise FileExistsError(output)
    policy = root / "dependencies/gui-host-notices"
    exclusions = json.loads((policy / "standard-terms.json").read_text())["excluded_targets"]
    if target in exclusions:
        raise ValueError(exclusions[target])
    if not same_checkout_lock((evidence_root / "Cargo.lock").read_bytes(), (root / "Cargo.lock").read_bytes()):
        raise ValueError("host source evidence uses a different checkout lock")
    fingerprint = source_fingerprint(root)
    evidence = json.loads((evidence_root / "evidence.json").read_text())
    if evidence["source_fingerprint"] != fingerprint:
        raise ValueError("Cargo build evidence has different source inputs")
    normalization_path = source / "normalization.json"
    normalization = json.loads(normalization_path.read_text()) if normalization_path.exists() else None
    validate_packaged_outputs(json.loads((evidence_root / "build.json").read_text()), target, fingerprint, evidence["host"],
                              {name: (source / name).read_bytes() for name in HOST_FILES[target]}, normalization)
    crates = crate_cache(evidence, cache)
    toolchains = json.loads((policy / "toolchains.json").read_text())
    rust = toolchains["rust"]["targets"][target]
    zig = toolchains["zig"]
    rust_archive = verified_download(rust["source_url"], rust["sha256"], cache / (rust["sha256"] + ".tar.xz"), rust.get("size"))
    zig_archive = verified_download(zig["source_url"], zig["sha256"], cache / (zig["sha256"] + ".tar.xz"), zig["size"])
    rust_target_archive = None
    if target == "x64mingw":
        target_pin = toolchain_license_inventory.selected_toolchains(toolchains, target)["rust-target"]
        rust_target_archive = verified_download(target_pin["source_url"], target_pin["sha256"],
                                                cache / (target_pin["sha256"] + ".tar.xz"), target_pin["size"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".host-release-") as temporary:
        stage = Path(temporary)
        candidate = stage / "candidate"
        candidate.mkdir()
        rust_license_inventory.collect(evidence_root / "selection.json", evidence_root / "Cargo.lock", crates,
                                       stage / "crate-notices", policy / "manifest.json", True, policy / "review.json", True)
        toolchain_license_inventory.collect(policy / "toolchains.json", target, rust_archive, zig_archive, stage / "toolchain-notices", rust_target_archive)
        source_archive = candidate / f"gui-host-sources-{target}.tar"
        normalization = source / "normalization.json"
        notices = compose(target, evidence_root, stage / "crate-notices", stage / "toolchain-notices", policy,
                          (source / HOST_FILES[target][0]).read_bytes(), source_archive, fingerprint,
                          normalization if normalization.exists() else None)
        notice_root = stage / "notices"
        notice_root.mkdir()
        for name, data in notices.items():
            (notice_root / name).write_bytes(data)
        host_archive = candidate / f"gui-host-{target}.tar"
        pack_host(target, source, host_archive, root, notice_root)
        check_candidate(host_archive, target, roc, root, source_archive)
        candidate.rename(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(HOST_FILES), required=True)
    parser.add_argument("--source", type=Path, help="Fresh host outputs matching the captured Cargo build")
    parser.add_argument("--cargo-evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/roc-signals/host-notices")
    parser.add_argument("--roc", default="roc")
    args = parser.parse_args()
    prepare(args.target, args.source or ROOT / "platform-gui/targets" / args.target, args.cargo_evidence,
            args.output, args.cache, str(Path(shutil.which(args.roc) or args.roc).resolve()))
