#!/usr/bin/env python3
"""Build and validate independently releasable macOS final-link interfaces."""

import argparse
import json
from pathlib import Path
import shutil
import tempfile

from build_macos_stubs import CATALOG, PROVENANCE, digest, read_catalog, render
from dependency_archive import write_archive

ROOT = Path(__file__).resolve().parents[1]
NAME = "macos-interfaces"
TARGET = "macos-sysroot"
IDENTITY = NAME + "-" + TARGET


def interface_files():
    """Return the exact target-relative inventory selected by the catalog."""
    return tuple(sorted(library["path"] for library in read_catalog()["libraries"]))


def build(output, *, root=ROOT):
    """Write deterministic catalog-derived interfaces without reading host or SDK bytes."""
    catalog_path = root / CATALOG.relative_to(ROOT)
    provenance_path = root / PROVENANCE.relative_to(ROOT)
    catalog_bytes = catalog_path.read_bytes()
    provenance = provenance_path.read_bytes()
    catalog = read_catalog(catalog_path)
    generated = render(catalog)
    manifest = {
        "schema_version": 1,
        "origin": "project-generated-macos-interfaces",
        "target": catalog["target"],
        "catalog_sha256": digest(catalog_bytes),
        "generator_sha256": digest(Path(__file__).read_bytes()),
        "provenance_sha256": digest(provenance),
        "files_sha256": {name: digest(data) for name, data in sorted(generated.items())},
    }
    prefix = f"targets/{TARGET}/"
    files = {prefix + name: data for name, data in generated.items()}
    files[prefix + "interfaces.json"] = catalog_bytes
    files[prefix + "PROVENANCE.md"] = provenance
    files[prefix + "manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    archive = output / f"{NAME}-{TARGET}.tar"
    write_archive(archive, {
        "schema_version": 1,
        "name": NAME,
        "target": TARGET,
        "catalog_sha256": manifest["catalog_sha256"],
    }, files)
    return archive


def check_candidate(archive, host_lock, roc, *, root=ROOT):
    """Final-link every maintained app against a candidate and a verified released host."""
    from dependency_artifacts import materialize, unpack_verified
    from host_build_identity import HOST_FILES
    from prepare_platforms import prepare_platform
    import check_macos_interfaces

    with tempfile.TemporaryDirectory(prefix="signals-macos-interfaces-") as temporary:
        stage = Path(temporary)
        extracted = stage / "interfaces"
        unpack_verified(archive, {"name": NAME, "target": TARGET}, extracted)
        platform = stage / "platform-gui"
        prepare_platform(root / "platform-gui", platform)
        host_target = "arm64mac"
        destination = platform / "targets" / host_target
        destination.mkdir(parents=True)
        hosts = stage / "hosts"
        identity = "gui-host-" + host_target
        materialize(host_lock, (identity,), Path.home() / ".cache/roc-signals/dependencies", hosts)
        source = hosts / identity / "targets" / host_target
        manifest = json.loads((hosts / identity / "dependency.json").read_text())
        expected = {f"targets/{host_target}/{name}" for name in HOST_FILES[host_target]}
        if not expected <= set(manifest["files"]):
            raise ValueError("released macOS host is missing required archives")
        for name in HOST_FILES[host_target]:
            shutil.copyfile(source / name, destination / name)
        shutil.copytree(extracted / "targets" / TARGET, platform / "targets" / TARGET)
        return check_macos_interfaces.check_apps(platform, roc, root=root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host-lock", type=Path)
    parser.add_argument("--roc", default="roc")
    args = parser.parse_args()
    archive = build(args.output.resolve())
    if args.host_lock is not None:
        check_candidate(archive, args.host_lock.resolve(), args.roc)
    print(archive)
