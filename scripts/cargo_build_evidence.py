"""Bind host notice selection to a successful native Cargo build and its lock."""

import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib

from host_build_identity import source_fingerprint

TARGETS = {"x64glibc": "x86_64-unknown-linux-gnu", "x64win": "x86_64-pc-windows-msvc",
           "arm64mac": "aarch64-apple-darwin", "x64mingw": "x86_64-pc-windows-gnullvm"}
COMPILER_HOSTS = dict(TARGETS, x64mingw="x86_64-pc-windows-msvc")


def metadata_graph(data):
    """Keep a filtered graph tied to one unambiguous host workspace root."""
    metadata = json.loads(data)
    packages = {p["id"]: p for p in metadata["packages"]}
    if len(packages) != len(metadata["packages"]):
        raise ValueError("duplicate Cargo metadata package")
    roots = [p for p in packages.values() if p["name"] == "signals-gpui-host" and p["source"] is None]
    if len(roots) != 1 or roots[0]["id"] not in metadata["workspace_members"]:
        raise ValueError("Cargo evidence needs the platform host workspace package")
    root = roots[0]["id"]
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    if len(nodes) != len(metadata["resolve"]["nodes"]):
        raise ValueError("duplicate Cargo metadata graph node")
    reachable, pending = set(), [root]
    while pending:
        identity = pending.pop()
        if identity in reachable:
            continue
        if identity not in nodes or identity not in packages:
            raise ValueError("incomplete Cargo metadata graph")
        reachable.add(identity)
        pending.extend(d["pkg"] for d in nodes[identity]["deps"]
                       if any(k["kind"] != "dev" for k in d["dep_kinds"]))
    return packages, root, reachable


def evidence_files(target):
    """Name original captured documents required to reproduce crate selection."""
    files = ("metadata.json", "cargo.jsonl", "Cargo.lock", "evidence.json", "selection.json", "build.json")
    return files + (("metadata-host.json",) if target == "x64mingw" else ())


def same_checkout_lock(captured, checkout):
    """Allow Git's Windows CRLF checkout while preserving all other lock bytes.

    Evidence retains and hashes the original captured bytes; this comparison is
    only for the same committed lock read from a different operating system.
    """
    return captured.replace(b"\r\n", b"\n") == checkout.replace(b"\r\n", b"\n")


def derive(metadata_bytes, messages_bytes, lock_bytes, target, host_bytes, host_record=None, *, fingerprint, host_metadata_bytes=None, compiler_host=None):
    """Select all compiled packages, including build tools, from complete output.

    The filtered metadata graph bounds package membership; original Cargo.lock
    identities bind registry packages. This is a conservative compilation set,
    not a claim that every selected object remains in the final static library.
    """
    packages, root, reachable = metadata_graph(metadata_bytes)
    if target == "x64mingw":
        if host_metadata_bytes is None or compiler_host != COMPILER_HOSTS[target]:
            raise ValueError("GNU host evidence requires its actual compiler-host metadata and identity")
        host_packages, host_root, host_reachable = metadata_graph(host_metadata_bytes)
        if host_root != root:
            raise ValueError("compiler-host metadata describes a different workspace")
        for identity, package in host_packages.items():
            if identity in packages and packages[identity] != package:
                raise ValueError("compiler-host and target metadata disagree on a package")
            packages[identity] = package
        reachable |= host_reachable
    elif host_metadata_bytes is not None or compiler_host is not None:
        raise ValueError("unexpected separate compiler-host metadata for a native target")
    compiled = set()
    scripts = []
    finished = False
    host_artifacts = []
    for line in messages_bytes.splitlines():
        if not line.startswith(b"{"):
            continue  # A procedural macro can write ordinary diagnostic text.
        message = json.loads(line)
        reason = message.get("reason")
        if finished:
            raise ValueError("Cargo messages follow build completion")
        if reason == "build-finished":
            if message.get("success") is not True:
                raise ValueError("Cargo evidence records an unsuccessful build")
            finished = True
        elif reason in ("compiler-artifact", "build-script-executed"):
            identity = message["package_id"]
            if identity not in reachable or identity not in packages:
                raise ValueError("compiled package is outside the host metadata graph")
            compiled.add(identity)
            if reason == "build-script-executed":
                scripts.append({k: message[k] for k in ("package_id", "linked_libs", "linked_paths")})
            elif identity == root and "staticlib" in message["target"]["kind"]:
                if message["profile"]["test"] or message["profile"]["opt_level"] != "3":
                    raise ValueError("host evidence requires the optimized library build")
                host_artifacts.append(message)
    if not finished or len(host_artifacts) != 1 or len(compiled) < 2:
        raise ValueError("incomplete Cargo host build evidence")
    host_name = "signals_gpui_host.lib" if target == "x64win" else "libsignals_gpui_host.a"
    if not any(name.replace("\\", "/").rsplit("/", 1)[-1] == host_name
               for name in host_artifacts[0]["filenames"]):
        raise ValueError("Cargo host artifact has an unexpected filename")
    if target == "x64mingw" and not any(name.replace("\\", "/").endswith("/" + TARGETS[target] + "/release/" + host_name)
                                      for name in host_artifacts[0]["filenames"]):
        raise ValueError("Cargo host artifact does not identify its explicit target build")
    if host_bytes is not None:
        original_host = {"name": host_name, "sha256": hashlib.sha256(host_bytes).hexdigest(), "size": len(host_bytes)}
        if host_record is not None and host_record != original_host:
            raise ValueError("Cargo host bytes differ from their recorded digest")
    else:
        if (not host_record or host_record.get("name") != host_name
                or not re.fullmatch(r"[0-9a-f]{64}", host_record.get("sha256", ""))
                or type(host_record.get("size")) is not int or host_record["size"] <= 0):
            raise ValueError("invalid original Cargo host digest")
        original_host = host_record
    locked = {(p["name"], p["version"], p.get("source")): p.get("checksum")
              for p in tomllib.loads(lock_bytes.decode())["package"]}
    selected = []
    report = []
    for identity in sorted(compiled):
        package = packages[identity]
        key = (package["name"], package["version"], package["source"])
        if key not in locked or (package["source"] is not None and not locked[key]):
            raise ValueError("compiled package has no Cargo.lock identity")
        if package["source"] is None and identity != root:
            raise ValueError("additional workspace packages require a notice policy")
        selected.append({"id": identity, "name": package["name"], "version": package["version"],
                         "source": package["source"], "crate_sha256": locked[key],
                         "declared_license": package["license"]})
        report.append({"package": package})
    evidence = {"schema_version": 1, "target": target, "rust_target": TARGETS[target],
                "source_fingerprint": fingerprint,
                "cargo_lock_sha256": hashlib.sha256(lock_bytes).hexdigest(),
                "metadata_sha256": hashlib.sha256(metadata_bytes).hexdigest(),
                "messages_sha256": hashlib.sha256(messages_bytes).hexdigest(),
                "host": original_host,
                "packages": selected, "build_script_links": scripts}
    if target == "x64mingw":
        evidence.update(schema_version=2, rust_host=compiler_host,
                        metadata_host_sha256=hashlib.sha256(host_metadata_bytes).hexdigest())
    return evidence, {"crates": report}


def capture(root, target, output, jobs, environment, expected_fingerprint=None):
    """Build once and atomically retain the exact messages used for selection."""
    if output.exists():
        raise FileExistsError(output)
    fingerprint = source_fingerprint(root)
    if expected_fingerprint is not None and fingerprint != expected_fingerprint:
        raise ValueError("host source changed before Cargo build")
    version = subprocess.check_output(["rustc", "--version", "--verbose"], env=environment, text=True)
    if not version.startswith("rustc 1.95.0 ") or "host: " + COMPILER_HOSTS[target] not in version.splitlines():
        raise ValueError("host notice evidence requires native Rust 1.95.0")
    lock = (root / "Cargo.lock").read_bytes()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".cargo-evidence-") as temporary:
        stage = Path(temporary) / "evidence"
        stage.mkdir()
        target_args = ["--target", TARGETS[target]] if target == "x64mingw" else []
        with (stage / "cargo.jsonl").open("wb") as messages:
            completed = subprocess.run(["cargo", "build", "--locked", "-p", "signals-gpui-host", "--lib", "--release",
                                        "-j", str(jobs), "--message-format=json-render-diagnostics", *target_args],
                                       cwd=root, env=environment, stdout=messages)
        for line in (stage / "cargo.jsonl").read_bytes().splitlines():
            if line.startswith(b"{"):
                message = json.loads(line)
                if message.get("reason") == "compiler-message" and message["message"].get("rendered"):
                    print(message["message"]["rendered"], file=sys.stderr, end="")
        completed.check_returncode()
        metadata = subprocess.check_output(["cargo", "metadata", "--locked", "--format-version=1",
                                            "--filter-platform", TARGETS[target]], cwd=root, env=environment)
        host_metadata = None
        if target == "x64mingw":
            host_metadata = subprocess.check_output(["cargo", "metadata", "--locked", "--format-version=1",
                                                     "--filter-platform", COMPILER_HOSTS[target]], cwd=root, env=environment)
        if lock != (root / "Cargo.lock").read_bytes():
            raise ValueError("Cargo.lock changed during the host build")
        host_name = "signals_gpui_host.lib" if target == "x64win" else "libsignals_gpui_host.a"
        host = Path(json.loads(metadata)["target_directory"])
        if target == "x64mingw":
            host /= TARGETS[target]
        host = host / "release" / host_name
        emitted = set()
        for line in (stage / "cargo.jsonl").read_bytes().splitlines():
            if line.startswith(b"{"):
                message = json.loads(line)
                if (message.get("reason") == "compiler-artifact"
                        and message["target"].get("name") == "signals_gpui_host"
                        and "staticlib" in message["target"]["kind"]):
                    emitted.update(Path(name).resolve() for name in message["filenames"])
        if host.resolve() not in emitted:
            raise ValueError("Cargo emitted a different host path; explicit target overrides require review")
        if source_fingerprint(root) != fingerprint:
            raise ValueError("host source changed during Cargo build")
        evidence, selection = derive(metadata, (stage / "cargo.jsonl").read_bytes(), lock, target, host.read_bytes(),
                                     fingerprint=fingerprint, host_metadata_bytes=host_metadata,
                                     compiler_host=COMPILER_HOSTS[target] if host_metadata is not None else None)
        if host_metadata is not None:
            (stage / "metadata-host.json").write_bytes(host_metadata)
        (stage / "metadata.json").write_bytes(metadata)
        (stage / "Cargo.lock").write_bytes(lock)
        (stage / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        (stage / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
        stage.rename(output)
    return host
