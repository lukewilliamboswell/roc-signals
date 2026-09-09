"""Collect original crate notices from Cargo.lock-verified download archives.

This inventory is evidence for notice review, not a declaration that every
package's licensing requirements are satisfied. Missing notice files remain
explicit; Cargo's license declaration is never substituted for a notice.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import tomllib

NOTICE = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|authors)(?:$|[._-])", re.I)
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def crate_notices(archive, package, expected_sha):
    """Check the published archive before reading declarations and notice bytes."""
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("missing or symlinked crate archive")
    with archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected_sha:
            raise ValueError("crate archive differs from Cargo.lock")
    prefix = package["name"] + "-" + package["version"]
    files = {}
    total = 0
    with tarfile.open(archive, "r:gz") as packed:
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts or
                    str(path) != member.name or "\\" in member.name or
                    not path.parts or path.parts[0] != prefix or len(path.parts) < 2):
                raise ValueError("unsafe crate archive member")
            relative = PurePosixPath(*path.parts[1:]).as_posix()
            if relative in files:
                raise ValueError("duplicate crate archive member")
            total += member.size
            if member.size < 0 or total > 512 * 1024 * 1024 or len(files) >= 20000:
                raise ValueError("crate archive exceeds inventory limits")
            files[relative] = member
        if "Cargo.toml" not in files:
            raise ValueError("crate has no published manifest")
        manifest_bytes = packed.extractfile(files["Cargo.toml"]).read()
        manifest = tomllib.loads(manifest_bytes.decode())["package"]
        if (manifest["name"], manifest["version"]) != (package["name"], package["version"]):
            raise ValueError("crate manifest identity differs from selected package")
        notices = {}
        for name, member in files.items():
            if NOTICE.match(PurePosixPath(name).name) or name == manifest.get("license-file"):
                notices[name] = packed.extractfile(member).read()
        # Preserve the publisher's declaration separately from actual notices.
        declarations = {"Cargo.toml": manifest_bytes}
        if "Cargo.toml.orig" in files:
            declarations["Cargo.toml.orig"] = packed.extractfile(files["Cargo.toml.orig"]).read()
        vcs = (json.load(packed.extractfile(files[".cargo_vcs_info.json"]))
               if ".cargo_vcs_info.json" in files else None)
    return manifest, notices, declarations, vcs


def upstream_notices(record, checksum, vcs, directory):
    """Accept local upstream notices only for the original published revision."""
    if (record["crate_sha256"] != checksum or not vcs or
            record["source_revision"] != vcs.get("git", {}).get("sha1")):
        raise ValueError("upstream notice does not match the published crate revision")
    notices = {}
    for notice in record["notices"]:
        path = PurePosixPath(notice["path"])
        if path.is_absolute() or ".." in path.parts or str(path) != notice["path"] or "\\" in str(path):
            raise ValueError("unsafe upstream notice path")
        source = directory / path
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(directory.resolve()):
            raise ValueError("invalid upstream notice file")
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != notice["sha256"]:
            raise ValueError("upstream notice differs from its reviewed hash")
        if notice["path"] in notices:
            raise ValueError("duplicate upstream notice")
        notices[notice["path"]] = data
    if not notices:
        raise ValueError("empty upstream notice record")
    return notices


def collect(about, lock, cache, destination, supplements=None, include_sources=False):
    """Publish a complete inventory atomically; any unknown identity stops it."""
    if destination.exists():
        raise FileExistsError(destination)
    locked_bytes = lock.read_bytes()
    locked = {(p["name"], p["version"], p.get("source")): p.get("checksum")
              for p in tomllib.loads(locked_bytes.decode())["package"]}
    report_bytes = about.read_bytes()
    report = json.loads(report_bytes)
    supplement_bytes = supplements.read_bytes() if supplements else None
    supplemental = json.loads(supplement_bytes) if supplements else {"schema_version": 1, "packages": {}}
    if supplemental["schema_version"] != 1:
        raise ValueError("unsupported upstream notice manifest")
    records = []
    own_packages = []
    seen = set()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".rust-notices-") as temporary:
        stage = Path(temporary) / "inventory"
        stage.mkdir()
        for item in report["crates"]:
            package = item["package"]
            if (not re.fullmatch(r"[A-Za-z0-9_-]+", package["name"]) or
                    not re.fullmatch(r"[A-Za-z0-9_.+-]+", package["version"])):
                raise ValueError("unsafe selected crate identity")
            identity = (package["name"], package["version"], package["source"])
            if identity in seen:
                raise ValueError("duplicate selected crate")
            seen.add(identity)
            if identity not in locked:
                raise ValueError("selected crate is absent from Cargo.lock")
            if package["source"] is None:
                own_packages.append({"name": package["name"], "version": package["version"]})
                continue
            if package["source"] != REGISTRY or not locked.get(identity):
                raise ValueError("selected crate has no supported Cargo.lock identity")
            stem = package["name"] + "-" + package["version"]
            archive = cache / (stem + ".crate")
            manifest, notices, declarations, vcs = crate_notices(archive, package, locked[identity])
            upstream = supplemental["packages"].get(package["name"] + "@" + package["version"])
            extra = upstream_notices(upstream, locked[identity], vcs, supplements.parent) if upstream else {}
            record = {"name": package["name"], "version": package["version"],
                      "crate_sha256": locked[identity], "declared_license": manifest.get("license"),
                      "authors": manifest.get("authors", []), "notice_files": {}, "declaration_files": {},
                      "upstream_notice_files": {}, "upstream_provenance": upstream}
            for category, payload in (("notice_files", notices), ("declaration_files", declarations),
                                      ("upstream_notice_files", extra)):
                for name, data in sorted(payload.items()):
                    relative = Path("crates") / stem / category / name
                    output = stage / relative
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(data)
                    record[category][name] = {"path": relative.as_posix(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
            if include_sources:
                # Retain the exact published source archive, including copyright
                # notices embedded in source comments. This does not resolve a
                # missing grant or establish the selected binary dependency set.
                data = archive.read_bytes()
                if hashlib.sha256(data).hexdigest() != locked[identity]:
                    raise ValueError("crate source archive changed during collection")
                relative = Path("sources") / archive.name
                (stage / relative).parent.mkdir(exist_ok=True)
                (stage / relative).write_bytes(data)
                record["source_archive"] = {"path": relative.as_posix(), "sha256": locked[identity],
                                            "size": len(data)}
            records.append(record)
        if not records:
            raise ValueError("no third-party crates selected for notice review")
        inventory = {"schema_version": 1, "cargo_lock_sha256": hashlib.sha256(locked_bytes).hexdigest(),
                     "about_report_sha256": hashlib.sha256(report_bytes).hexdigest(),
                     "packages": sorted(records, key=lambda p: (p["name"], p["version"])),
                     "workspace_packages": own_packages,
                     "supplements_sha256": hashlib.sha256(supplement_bytes).hexdigest() if supplements else None,
                     "missing_notice_files": sorted(p["name"] + "@" + p["version"] for p in records
                                                    if not p["notice_files"] and not p["upstream_notice_files"])}
        (stage / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
        stage.rename(destination)
    return inventory


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--about", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True, help="Cargo registry archive cache directory")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--supplements", type=Path, help="Reviewed, revision-bound upstream notice manifest")
    parser.add_argument("--include-sources", action="store_true", help="Retain every selected original crate source archive")
    args = parser.parse_args()
    result = collect(args.about, args.lock, args.cache, args.output, args.supplements, args.include_sources)
    print(f"Verified {len(result['packages'])} crate archives; {len(result['missing_notice_files'])} lack notice files")
