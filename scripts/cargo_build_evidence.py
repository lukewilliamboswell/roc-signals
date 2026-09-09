"""Bind host notice selection to a successful native Cargo build and its lock."""

import atexit
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
           "arm64mac": "aarch64-apple-darwin"}


def derive(metadata_bytes, messages_bytes, lock_bytes, target, host_bytes, host_record=None, *, fingerprint):
    """Select all compiled packages, including build tools, from complete output.

    The filtered metadata graph bounds package membership; original Cargo.lock
    identities bind registry packages. This is a conservative compilation set,
    not a claim that every selected object remains in the final static library.
    """
    metadata = json.loads(metadata_bytes)
    packages = {p["id"]: p for p in metadata["packages"]}
    if len(packages) != len(metadata["packages"]):
        raise ValueError("duplicate Cargo metadata package")
    roots = [p for p in packages.values() if p["name"] == "signals-gpui-host" and p["source"] is None]
    if len(roots) != 1 or roots[0]["id"] not in metadata["workspace_members"]:
        raise ValueError("Cargo evidence needs the platform host workspace package")
    root = roots[0]["id"]
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    reachable = set()
    pending = [root]
    while pending:
        identity = pending.pop()
        if identity in reachable:
            continue
        reachable.add(identity)
        pending.extend(d["pkg"] for d in nodes[identity]["deps"]
                       if any(k["kind"] != "dev" for k in d["dep_kinds"]))
    freetype = {identity for identity in reachable if packages[identity]["name"] == "freetype-sys"}
    if target == "x64glibc" and any(packages[identity]["version"] != "0.20.1"
                                    or packages[identity].get("links") != "freetype" for identity in freetype):
        raise ValueError("review the FreeType native link override for this dependency")
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
            if target == "x64glibc" and identity in freetype and (
                    reason == "build-script-executed" or "custom-build" in message["target"]["kind"]):
                raise ValueError("FreeType build script ran instead of the independent library override")
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
    return evidence, {"crates": report}


def macos_toolchain(environment):
    """Identify the selected shader tools without copying Apple distribution files."""
    def query(*arguments):
        return subprocess.check_output(arguments, env=environment, text=True).strip()
    tools = {}
    for name in ("metal", "metallib"):
        path = Path(query("xcrun", "-sdk", "macosx", "--find", name))
        version = subprocess.run([str(path), "--version"], env=environment, capture_output=True, text=True, timeout=30)
        tools[name] = {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                       "version_status": version.returncode, "version_output": version.stdout + version.stderr}
    return {"xcode": query("xcodebuild", "-version"),
            "sdk_version": query("xcrun", "-sdk", "macosx", "--show-sdk-version"),
            "sdk_build": query("xcrun", "-sdk", "macosx", "--show-sdk-build-version"),
            "tools": tools}


def macos_shaders(metadata, messages, target_directory, toolchain, host_digest):
    """Bind fresh GPUI shader outputs to their Cargo package and resulting host."""
    packages = [p for p in metadata["packages"] if p["name"] == "gpui"]
    if len(packages) != 1 or packages[0]["version"] != "0.2.2":
        raise ValueError("review Mac shader inputs for the selected GPUI version")
    package = packages[0]
    records = [json.loads(line) for line in messages.splitlines() if line.startswith(b"{")]
    outputs = [Path(m["out_dir"]).resolve() for m in records
               if m.get("reason") == "build-script-executed" and m["package_id"] == package["id"]]
    if len(outputs) != 1 or not outputs[0].is_relative_to(target_directory.resolve()):
        raise ValueError("missing fresh GPUI shader output directory")
    def record(path):
        data = path.read_bytes()
        if not data:
            raise ValueError("empty GPUI shader input or output")
        return {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    return {"toolchain": toolchain, "gpui_package_id": package["id"],
            "cargo_host_sha256": host_digest, "fresh_cargo_target": True,
            "shader_source": record(Path(package["manifest_path"]).parent / "src/platform/mac/shaders.metal"),
            "outputs": {name: record(outputs[0] / name) for name in ("scene.h", "shaders.air", "shaders.metallib")}}


def capture(root, target, output, jobs, environment, expected_fingerprint=None):
    """Build once and atomically retain the exact messages used for selection."""
    if output.exists():
        raise FileExistsError(output)
    if target == "x64glibc":
        configuration = tomllib.loads((root / ".cargo/config.toml").read_text())
        if configuration.get("target", {}).get(TARGETS[target], {}).get("freetype") != {"rustc-link-lib": ["dylib=freetype"]}:
            raise ValueError("Linux host requires the independent FreeType Cargo override")
    fingerprint = source_fingerprint(root)
    if expected_fingerprint is not None and fingerprint != expected_fingerprint:
        raise ValueError("host source changed before Cargo build")
    version = subprocess.check_output(["rustc", "--version", "--verbose"], env=environment, text=True)
    if not version.startswith("rustc 1.95.0 ") or "host: " + TARGETS[target] not in version.splitlines():
        raise ValueError("host notice evidence requires native Rust 1.95.0")
    lock = (root / "Cargo.lock").read_bytes()
    output.parent.mkdir(parents=True, exist_ok=True)
    apple_tools = macos_toolchain(environment) if target == "arm64mac" else None
    if apple_tools is not None:
        # A release receipt cannot attribute cached shaders to today's tools.
        # Keep this target alive until build_gui has copied the resulting host.
        scratch = tempfile.TemporaryDirectory(prefix=".macos-cargo-", dir=output.parent)
        # Registering the bound cleanup retains the directory until build_gui
        # has copied the returned host, then removes it when that process exits.
        atexit.register(scratch.cleanup)
        environment = dict(environment, CARGO_TARGET_DIR=scratch.name)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".cargo-evidence-") as temporary:
        stage = Path(temporary) / "evidence"
        stage.mkdir()
        with (stage / "cargo.jsonl").open("wb") as messages:
            completed = subprocess.run(["cargo", "build", "--locked", "-p", "signals-gpui-host", "--lib", "--release",
                                        "-j", str(jobs), "--message-format=json-render-diagnostics"],
                                       cwd=root, env=environment, stdout=messages)
        for line in (stage / "cargo.jsonl").read_bytes().splitlines():
            if line.startswith(b"{"):
                message = json.loads(line)
                if message.get("reason") == "compiler-message" and message["message"].get("rendered"):
                    print(message["message"]["rendered"], file=sys.stderr, end="")
        completed.check_returncode()
        metadata = subprocess.check_output(["cargo", "metadata", "--locked", "--format-version=1",
                                            "--filter-platform", TARGETS[target]], cwd=root, env=environment)
        if lock != (root / "Cargo.lock").read_bytes():
            raise ValueError("Cargo.lock changed during the host build")
        host_name = "signals_gpui_host.lib" if target == "x64win" else "libsignals_gpui_host.a"
        host = Path(json.loads(metadata)["target_directory"]) / "release" / host_name
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
        evidence, selection = derive(metadata, (stage / "cargo.jsonl").read_bytes(), lock, target, host.read_bytes(), fingerprint=fingerprint)
        if apple_tools is not None:
            if macos_toolchain(environment) != apple_tools:
                raise ValueError("Mac shader toolchain changed during compilation")
            shaders = macos_shaders(json.loads(metadata), (stage / "cargo.jsonl").read_bytes(),
                                    Path(json.loads(metadata)["target_directory"]), apple_tools, evidence["host"]["sha256"])
            (stage / "macos.json").write_text(json.dumps(shaders, indent=2) + "\n")
        (stage / "metadata.json").write_bytes(metadata)
        (stage / "Cargo.lock").write_bytes(lock)
        (stage / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        (stage / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
        stage.rename(output)
    return host
