"""Compose original host notices and a separately retained source companion."""

import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

from cargo_build_evidence import derive
from host_build_identity import validate_outputs
from dependency_archive import write_archive
from rust_license_inventory import EMBEDDED_NOTICE

CATEGORIES = ("notice_files", "declaration_files", "upstream_notice_files", "reviewed_source_files",
              "reviewed_upstream_files", "embedded_notice_files")
NOTICE_FILES = ("NOTICE.md", "NOTICE.json", "third-party-notices.tar.xz")
SOURCE_KIND = "gui-host-sources"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_normalization(receipt, target, original_host, host_bytes, outputs=None):
    """Bind recorded compaction inputs to the bytes actually being distributed."""
    if receipt.get("schema_version") != 1 or receipt["target"] != target:
        raise ValueError("normalization receipt has a different target or schema")
    host_name = original_host["name"]
    engine_name = "engine.lib" if target == "x64win" else "libengine.a"
    if host_name not in receipt["archives"] or not set(receipt["archives"]) <= {host_name, engine_name}:
        raise ValueError("normalization receipt names unexpected archives")
    host = receipt["archives"][host_name]
    if (host["input"] != {k: original_host[k] for k in ("sha256", "size")}
            or host["output"] != {"sha256": digest(host_bytes), "size": len(host_bytes)}):
        raise ValueError("normalization receipt differs from original or final host bytes")
    for tool in receipt["tools"].values():
        if not re.fullmatch(r"[0-9a-f]{64}", tool["sha256"]) or not tool["version"]:
            raise ValueError("normalization receipt has an invalid tool identity")
    for name, archive in receipt["archives"].items():
        if not archive["steps"]:
            raise ValueError("normalization receipt omits archive steps")
        for step in archive["steps"]:
            if step["tool"] not in receipt["tools"] or not step["args"] or not all(isinstance(a, str) for a in step["args"]):
                raise ValueError("normalization step has no recorded tool or arguments")
        if outputs is not None:
            if name not in outputs or archive["output"] != {"sha256": digest(outputs[name]), "size": len(outputs[name])}:
                raise ValueError("normalization receipt differs from packaged archive bytes")


def checked_file(root, name, record):
    """Read an indexed regular file without trusting its path or cached bytes."""
    path = PurePosixPath(name)
    if not path.parts or path.is_absolute() or ".." in path.parts or str(path) != name or "\\" in name:
        raise ValueError("unsafe notice payload path")
    source = root / name
    if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(root.resolve()):
        raise ValueError("invalid notice payload file")
    data = source.read_bytes()
    if digest(data) != record["sha256"] or ("size" in record and len(data) != record["size"]):
        raise ValueError("notice payload file differs from its inventory")
    return data


def pack_notices(files):
    """Compress exact notice bytes with a deterministic, self-checking index."""
    inventory = {name: {"sha256": digest(data), "size": len(data)} for name, data in sorted(files.items())}
    payload = dict(files, **{"inventory.json": (json.dumps(inventory, indent=2) + "\n").encode()})
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:xz", format=tarfile.PAX_FORMAT, preset=9) as packed:
        for name, data in sorted(payload.items()):
            member = tarfile.TarInfo(name)
            member.mode = 0o644
            member.size = len(data)
            packed.addfile(member, io.BytesIO(data))
    return output.getvalue()


def validate_notice_archive(data):
    """Check all inner notice bytes without extracting their source paths."""
    actual = {}
    inventory = None
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as packed:
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts
                    or str(path) != member.name or "\\" in member.name):
                raise ValueError("unsafe notice archive member")
            total += member.size
            if member.size < 0 or total > 1024 ** 3 or len(actual) >= 20000:
                raise ValueError("notice archive exceeds limits")
            if member.name == "inventory.json":
                if inventory is not None or member.size > 8 * 1024 ** 2:
                    raise ValueError("invalid notice archive index")
                inventory = json.load(packed.extractfile(member))
            else:
                if member.name in actual:
                    raise ValueError("duplicate notice archive member")
                actual[member.name] = {"sha256": hashlib.file_digest(packed.extractfile(member), "sha256").hexdigest(),
                                       "size": member.size}
    if not actual or inventory != actual:
        raise ValueError("notice archive differs from its index")
    return actual


def notice_json(data, name):
    """Read one indexed JSON document after validating the notice archive."""
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as packed:
        for member in packed:
            if member.name == name:
                if member.size > 8 * 1024 ** 2:
                    raise ValueError("notice document exceeds size limit")
                return json.load(packed.extractfile(member))
    raise ValueError("missing notice document")


def validate_notices(directory, target, host_bytes, fingerprint, policy_root, outputs=None):
    """Admit only a complete notice payload bound to these exact host bytes."""
    manifest = json.loads((directory / "NOTICE.json").read_text())
    policy_bytes = (policy_root / "standard-terms.json").read_bytes()
    policy = json.loads(policy_bytes)
    if target in policy["excluded_targets"]:
        raise ValueError(policy["excluded_targets"][target])
    if (manifest.get("schema_version") != 1 or manifest["target"] != target
            or manifest["source_fingerprint"] != fingerprint or manifest["policy_sha256"] != digest(policy_bytes)
            or manifest["host"]["sha256"] != digest(host_bytes) or manifest["host"]["size"] != len(host_bytes)):
        raise ValueError("notice payload does not match host bytes, source, or policy")
    data = checked_file(directory, "third-party-notices.tar.xz", manifest["notice_archive"])
    index = validate_notice_archive(data)
    if index.get("build.json") != manifest["build_receipt"]:
        raise ValueError("notice archive omits captured host build receipt")
    validate_outputs(notice_json(data, "build.json"), target, fingerprint, manifest["cargo_host"], outputs)
    if manifest.get("normalization") is not None:
        if index.get("normalization.json") != manifest["normalization"]:
            raise ValueError("notice archive omits the normalization receipt")
        receipt = notice_json(data, "normalization.json")
        validate_normalization(receipt, target, manifest["cargo_host"], host_bytes, outputs)
    elif manifest["cargo_host"] != manifest["host"]:
        raise ValueError("changed Cargo host bytes have no normalization receipt")
    if index.get("referenced-standard-terms/policy.json", {}).get("sha256") != digest(policy_bytes):
        raise ValueError("notice archive has a different standard-terms policy")
    seen = set()
    for package in manifest["packages"]:
        identity = (package["name"], package["version"])
        if identity in seen or package["declared_license"] not in policy["expressions"]:
            raise ValueError("duplicate package or unreviewed notice license expression")
        seen.add(identity)
        terms = policy["expressions"][package["declared_license"]]
        if package["referenced_standard_terms"] != terms:
            raise ValueError("notice package selects different standard terms")
        for term in terms:
            if index.get("referenced-standard-terms/" + term + ".txt", {}).get("sha256") != policy["terms"][term]["sha256"]:
                raise ValueError("notice archive omits required standard terms")
    if not seen:
        raise ValueError("notice payload has no third-party packages")
    crates = notice_json(data, "crate-inventory.json")
    if (not crates.get("embedded_notice_scan") or crates["cargo_lock_sha256"] != manifest["cargo_lock_sha256"]
            or {(p["name"], p["version"]) for p in crates["packages"]} != seen
            or len(crates["packages"]) != len(seen)):
        raise ValueError("notice archive has an incomplete crate evidence inventory")
    for package in crates["packages"]:
        for category in CATEGORIES:
            for record in package[category].values():
                if index.get(record["path"]) != {"sha256": record["sha256"], "size": record["size"]}:
                    raise ValueError("notice archive omits original crate evidence")
    tools = notice_json(data, "toolchain-inventory.json")
    recipe_bytes = (policy_root / "toolchains.json").read_bytes()
    recipe = json.loads(recipe_bytes)
    if (tools["target"] != target or tools["recipe_sha256"] != digest(recipe_bytes)
            or tools["toolchains"] != manifest["toolchains"]):
        raise ValueError("notice archive uses different toolchain evidence")
    for name in ("rust", "zig"):
        selected_recipe = recipe[name]["targets"][target] if name == "rust" else recipe[name]
        if tools["toolchains"][name] != {"version": recipe[name]["version"],
                                         "archive_sha256": selected_recipe["sha256"],
                                         "source_url": selected_recipe["source_url"]}:
            raise ValueError("notice toolchain differs from pinned distribution")
        for path in selected_recipe["notices"]:
            record = tools["files"]["notices/" + name + "/" + path]
            if index.get("toolchains/notices/" + name + "/" + path) != record:
                raise ValueError("notice archive omits original runtime notices")
    companion = manifest["source_companion"]
    if (companion["name"] != SOURCE_KIND or companion["target"] != target
            or companion["asset"] != f"{SOURCE_KIND}-{target}.tar"):
        raise ValueError("notice payload names an unexpected source companion")
    return manifest, data


def validate_sources(source_tree, manifest, notice_data, host_bytes, lock_bytes):
    """Verify the companion's complete compiled-source set before publication."""
    dependency = json.loads((source_tree / "dependency.json").read_text())
    if dependency.get("source_fingerprint") != manifest["source_fingerprint"]:
        raise ValueError("source companion comes from different host inputs")
    prefix = "licenses/gui-host-sources/"
    evidence_root = source_tree / prefix / "evidence"
    if (evidence_root / "Cargo.lock").read_bytes() != lock_bytes:
        raise ValueError("source companion uses a different Cargo.lock")
    evidence, selection = derive((evidence_root / "metadata.json").read_bytes(),
                                 (evidence_root / "cargo.jsonl").read_bytes(), lock_bytes,
                                 manifest["target"], None, manifest["cargo_host"],
                                 fingerprint=manifest["source_fingerprint"])
    if (evidence != json.loads((evidence_root / "evidence.json").read_text())
            or selection != json.loads((evidence_root / "selection.json").read_text())):
        raise ValueError("source companion build evidence is inconsistent")
    build_bytes = checked_file(source_tree, prefix + "evidence/build.json", manifest["build_receipt"])
    if json.loads(build_bytes) != notice_json(notice_data, "build.json"):
        raise ValueError("source companion has different host build receipt")
    validate_outputs(json.loads(build_bytes), manifest["target"], manifest["source_fingerprint"], manifest["cargo_host"])
    expected_packages = {p["id"]: p for p in evidence["packages"] if p["source"] is not None}
    observed = {p["id"]: {k: v for k, v in p.items() if k != "referenced_standard_terms"}
                for p in manifest["packages"]}
    if observed != expected_packages:
        raise ValueError("notice packages differ from the compiled source companion")
    crates = notice_json(notice_data, "crate-inventory.json")
    tools = notice_json(notice_data, "toolchain-inventory.json")
    expected_files = {prefix + "evidence/" + name for name in
                      ("metadata.json", "cargo.jsonl", "Cargo.lock", "evidence.json", "selection.json", "build.json")}
    if manifest.get("normalization") is not None:
        receipt_bytes = checked_file(source_tree, prefix + "evidence/normalization.json", manifest["normalization"])
        validate_normalization(json.loads(receipt_bytes), manifest["target"], manifest["cargo_host"], host_bytes)
        expected_files.add(prefix + "evidence/normalization.json")
    by_identity = {(p["name"], p["version"]): p for p in expected_packages.values()}
    for package in crates["packages"]:
        record = package["source_archive"]
        matched = by_identity.get((package["name"], package["version"]))
        if not matched or record["sha256"] != matched["crate_sha256"]:
            raise ValueError("source companion crate differs from compiled lock identity")
        path = prefix + record["path"]
        checked_file(source_tree, path, record)
        expected_files.add(path)
    for path, record in tools["files"].items():
        if path.startswith("sources/"):
            if record["sha256"] != manifest["toolchains"]["zig"]["archive_sha256"]:
                raise ValueError("source companion Zig archive differs from pinned input")
            name = prefix + "toolchains/" + path
            checked_file(source_tree, name, record)
            expected_files.add(name)
    if set(dependency["files"]) != expected_files:
        raise ValueError("source companion inventory is incomplete or unexpected")


def compose(target, evidence_root, crate_root, toolchain_root, policy_root, host_bytes, source_output, fingerprint, normalization=None):
    """Build complete notice bytes and the source asset bound into their index.

    Original notices and declarations remain distinct from standard reference
    terms. Source archives accompany the release rather than being expanded into
    an application's platform package. Target exclusions are explicit policy.
    """
    policy_bytes = (policy_root / "standard-terms.json").read_bytes()
    policy = json.loads(policy_bytes)
    if target in policy["excluded_targets"]:
        raise ValueError(policy["excluded_targets"][target])
    metadata = (evidence_root / "metadata.json").read_bytes()
    messages = (evidence_root / "cargo.jsonl").read_bytes()
    lock = (evidence_root / "Cargo.lock").read_bytes()
    recorded_evidence = json.loads((evidence_root / "evidence.json").read_text())
    if recorded_evidence["source_fingerprint"] != fingerprint:
        raise ValueError("Cargo build evidence has different source inputs")
    build_bytes = (evidence_root / "build.json").read_bytes()
    validate_outputs(json.loads(build_bytes), target, fingerprint, recorded_evidence["host"])
    normalization_bytes = normalization.read_bytes() if normalization is not None else None
    if normalization_bytes is not None:
        validate_normalization(json.loads(normalization_bytes), target, recorded_evidence["host"], host_bytes)
    evidence, selection = derive(metadata, messages, lock, target,
                                 host_bytes if normalization_bytes is None else None,
                                 recorded_evidence["host"] if normalization_bytes is not None else None,
                                 fingerprint=fingerprint)
    if evidence != recorded_evidence:
        raise ValueError("Cargo build evidence changed before notice composition")
    if selection != json.loads((evidence_root / "selection.json").read_text()):
        raise ValueError("Cargo notice selection differs from the compiled package set")
    crates = json.loads((crate_root / "inventory.json").read_text())
    if (crates["cargo_lock_sha256"] != digest(lock) or not crates.get("embedded_notice_scan")
            or crates["about_report_sha256"] != digest((evidence_root / "selection.json").read_bytes())
            or crates["supplements_sha256"] != digest((policy_root / "manifest.json").read_bytes())
            or crates["review_sha256"] != digest((policy_root / "review.json").read_bytes())):
        raise ValueError("crate notice inventory differs from the build or reviewed inputs")
    expected = {(p["name"], p["version"]): p for p in evidence["packages"] if p["source"] is not None}
    if len(crates["packages"]) != len(expected) or {(p["name"], p["version"]) for p in crates["packages"]} != set(expected):
        raise ValueError("notice inventory does not cover the compiled package set")
    files = {"build.json": build_bytes}
    sources = {}
    if normalization_bytes is not None:
        files["normalization.json"] = normalization_bytes
        sources["licenses/gui-host-sources/evidence/normalization.json"] = normalization_bytes
    selected = []
    for package in crates["packages"]:
        identity = (package["name"], package["version"])
        compiled = expected[identity]
        if (package["crate_sha256"] != compiled["crate_sha256"]
                or package["declared_license"] != compiled["declared_license"]):
            raise ValueError("crate declaration differs from compiled package metadata")
        expression = package["declared_license"]
        if expression not in policy["expressions"]:
            raise ValueError(f"unreviewed Cargo license expression: {expression}")
        terms = policy["expressions"][expression]
        for term in terms:
            entry = policy["terms"][term]
            files["referenced-standard-terms/" + term + ".txt"] = checked_file(policy_root, entry["path"], entry)
        for category in CATEGORIES:
            for entry in package[category].values():
                files[entry["path"]] = checked_file(crate_root, entry["path"], entry)
        source = package["source_archive"]
        if source["sha256"] != compiled["crate_sha256"]:
            raise ValueError("source companion contains an unlocked crate")
        sources["licenses/gui-host-sources/" + source["path"]] = checked_file(crate_root, source["path"], source)
        selected.append(dict(compiled, referenced_standard_terms=terms))
    toolchains = json.loads((toolchain_root / "inventory.json").read_text())
    toolchain_recipe = json.loads((policy_root / "toolchains.json").read_text())
    if (toolchains["target"] != target
            or toolchains["recipe_sha256"] != digest((policy_root / "toolchains.json").read_bytes())):
        raise ValueError("toolchain notice inventory differs from the selected target recipe")
    required = {"notices/rust/" + p for p in toolchain_recipe["rust"]["targets"][target]["notices"]}
    required.update("notices/zig/" + p for p in toolchain_recipe["zig"]["notices"])
    zig_source = "sources/zig-" + toolchain_recipe["zig"]["version"] + ".tar.xz"
    required.add(zig_source)
    if set(toolchains["files"]) != required:
        raise ValueError("toolchain notice inventory is incomplete")
    for name, entry in toolchains["files"].items():
        data = checked_file(toolchain_root, name, entry)
        if name == zig_source:
            if digest(data) != toolchain_recipe["zig"]["sha256"]:
                raise ValueError("Zig source differs from its pinned distribution")
            sources["licenses/gui-host-sources/toolchains/" + name] = data
            prefix = toolchain_recipe["zig"]["prefix"] + "/"
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as packed:
                for member in packed:
                    relative = member.name.removeprefix(prefix)
                    if member.isfile() and relative.startswith(("lib/std/", "lib/compiler_rt/", "lib/compiler_rt.zig")):
                        original = packed.extractfile(member).read()
                        if EMBEDDED_NOTICE.search(original):
                            files["toolchains/zig-runtime-source-notices/" + relative] = original
        else:
            files["toolchains/" + name] = data
    files["crate-inventory.json"] = (crate_root / "inventory.json").read_bytes()
    files["toolchain-inventory.json"] = (toolchain_root / "inventory.json").read_bytes()
    files["referenced-standard-terms/policy.json"] = policy_bytes
    for name in ("metadata.json", "cargo.jsonl", "Cargo.lock", "evidence.json", "selection.json", "build.json"):
        sources["licenses/gui-host-sources/evidence/" + name] = (evidence_root / name).read_bytes()
    notice_bytes = pack_notices(files)
    validate_notice_archive(notice_bytes)
    source_archive = write_archive(source_output, {
        "schema_version": 1, "name": SOURCE_KIND, "target": target, "source_fingerprint": fingerprint,
    }, sources)
    source_bytes = source_archive.read_bytes()
    manifest = {"schema_version": 1, "target": target, "source_fingerprint": fingerprint,
                "cargo_lock_sha256": digest(lock), "policy_sha256": digest(policy_bytes),
                "host": {"name": evidence["host"]["name"], "sha256": digest(host_bytes), "size": len(host_bytes)},
                "cargo_host": evidence["host"],
                "build_receipt": {"sha256": digest(build_bytes), "size": len(build_bytes)},
                "normalization": {"sha256": digest(normalization_bytes), "size": len(normalization_bytes)} if normalization_bytes is not None else None,
                "packages": selected, "toolchains": toolchains["toolchains"],
                "source_companion": {"name": SOURCE_KIND, "target": target, "asset": source_output.name,
                                     "sha256": digest(source_bytes), "size": len(source_bytes)},
                "notice_archive": {"sha256": digest(notice_bytes), "size": len(notice_bytes)}}
    explanation = (
        "# GUI host third-party notices\n\n"
        "Extract third-party-notices.tar.xz to read the original notices, declarations, "
        "and runtime notices. Its crate directories also retain complete files containing "
        "copyright or license markers; these may include source code and documentation.\n\n"
        "referenced-standard-terms contains pinned SPDX reference texts selected by the "
        "publishers' Cargo license declarations. These texts, including any template attribution, "
        "are not fabricated crate-specific copyright notices. Original notices and declarations "
        "are retained separately.\n\n"
        f"The same release contains {source_output.name}, with the complete selected original "
        "crate sources, Zig sources, and build evidence. NOTICE.json records its exact digest "
        "and the corresponding packages. Retain the notice archive when redistributing the host.\n"
    ).encode()
    return {"NOTICE.md": explanation, "NOTICE.json": (json.dumps(manifest, indent=2) + "\n").encode(),
            "third-party-notices.tar.xz": notice_bytes}
