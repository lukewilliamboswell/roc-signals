"""Identify committed host build inputs and every host-owned output."""

import hashlib
import json
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HOST_FILES = {
    "x64glibc": ("libsignals_gpui_host.a", "libengine.a"),
    "arm64mac": ("libsignals_gpui_host.a", "libengine.a"),
    "x64win": ("signals_gpui_host.lib", "engine.lib", "signals.res"),
    "x64mingw": ("libsignals_gpui_host.a", "libengine.a", "signals.res"),
}
SOURCE_PATHS = (
    "src/native_host.zig", "src/signals", "crates/gpui-host", "platform-gui", "platform-shared",
    ".cargo/config.toml",
    "scripts/audit_windows_archive.py", "scripts/build_glibc.py", "scripts/build_gui.py",
    "scripts/build_macos_stubs.py", "scripts/build_windows_gnu_runtime.py",
    "scripts/build_windows_system_imports.py", "scripts/cargo_build_evidence.py",
    "scripts/compiler_pins.py", "scripts/dependency_archive.py", "scripts/dependency_artifacts.py",
    "scripts/gui_host_artifacts.py", "scripts/gui_suite.py", "scripts/host_build_identity.py",
    "scripts/host_notice_payload.py", "scripts/prepare_dependencies.py",
    "scripts/prepare_gui_host_release.py", "scripts/prepare_platforms.py",
    "scripts/release_dependencies.py", "scripts/release_gui_hosts.py",
    "scripts/rust_license_inventory.py", "scripts/spec_driver.py", "scripts/toolchain.py",
    "scripts/toolchain_license_inventory.py", "scripts/windows_gnu_build.py",
    "scripts/windows_gnu_coff.py", "scripts/windows_runtime_validation.py",
    "scripts/windows_system_imports.py",
    "dependencies/gui-host-notices", "dependencies/macos-interfaces",
    ".github/actions/setup-toolchain", ".github/workflows/gui-hosts.yml",
    "build.zig", "build.zig.zon", "Cargo.toml", "Cargo.lock", "dependencies.lock.json", "LICENSE",
    ".gitattributes", ".gitignore",
)


def source_fingerprint(root=ROOT):
    """Bind admission to clean committed inputs across checkout line endings."""
    changed = subprocess.run([
        "git", "diff", "--quiet", "HEAD", "--", *SOURCE_PATHS,
    ], cwd=root).returncode
    untracked = subprocess.check_output([
        "git", "ls-files", "--others", "--exclude-standard", "-z", "--", *SOURCE_PATHS,
    ], cwd=root)
    if changed or untracked:
        raise ValueError("prebuilt hosts require clean committed host source inputs")
    tree = subprocess.check_output([
        "git", "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *SOURCE_PATHS,
    ], cwd=root)
    if not tree:
        raise ValueError("host source inventory is empty")
    for record in tree.split(b"\0"):
        if record and not record.startswith((b"100644 blob ", b"100755 blob ")):
            raise ValueError("host source inventory must contain regular files")
    return hashlib.sha256(tree).hexdigest()


def record_outputs(root, target, destination, evidence_root, fingerprint):
    """Seal successful Zig, Cargo and resource outputs under their build inputs."""
    if source_fingerprint(root) != fingerprint:
        raise ValueError("host source changed during the complete build")
    evidence = json.loads((evidence_root / "evidence.json").read_text())
    if evidence["source_fingerprint"] != fingerprint:
        raise ValueError("Cargo evidence has different build source inputs")
    outputs = {}
    for name in HOST_FILES[target]:
        path = destination / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("missing or invalid host build output")
        data = path.read_bytes()
        outputs[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    receipt = {"schema_version": 1, "target": target, "source_fingerprint": fingerprint, "outputs": outputs}
    if target == "arm64mac":
        receipt["macos"] = json.loads((evidence_root / "macos.json").read_text())
    validate_outputs(receipt, target, fingerprint, evidence["host"])
    if source_fingerprint(root) != fingerprint:
        raise ValueError("host source changed while capturing build outputs")
    with (evidence_root / "build.json").open("x") as output:
        output.write(json.dumps(receipt, indent=2) + "\n")


def validate_outputs(receipt, target, fingerprint, cargo_host, outputs=None):
    """Reject source relabeling and replacement of any captured host output."""
    if (receipt.get("schema_version") != 1 or receipt["target"] != target
            or receipt["source_fingerprint"] != fingerprint
            or set(receipt["outputs"]) != set(HOST_FILES[target])):
        raise ValueError("host build receipt differs from source or target inventory")
    if receipt["outputs"][HOST_FILES[target][0]] != {k: cargo_host[k] for k in ("sha256", "size")}:
        raise ValueError("host build receipt differs from Cargo output")
    if target == "arm64mac":
        macos = receipt.get("macos", {})
        if (macos.get("cargo_host_sha256") != cargo_host["sha256"] or macos.get("fresh_cargo_target") is not True
                or set(macos.get("outputs", {})) != {"scene.h", "shaders.air", "shaders.metallib"}
                or set(macos.get("toolchain", {}).get("tools", {})) != {"metal", "metallib"}):
            raise ValueError("Mac shader evidence differs from the captured host")
        for record in (*macos["outputs"].values(), macos.get("shader_source", {})):
            if (not re.fullmatch(r"[0-9a-f]{64}", record.get("sha256", ""))
                    or type(record.get("size")) is not int or record["size"] <= 0):
                raise ValueError("invalid Mac shader input or output digest")
        if any(not re.fullmatch(r"[0-9a-f]{64}", tool.get("sha256", ""))
               for tool in macos["toolchain"]["tools"].values()):
            raise ValueError("invalid Mac shader tool digest")
    if outputs is not None:
        observed = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                    for name, data in outputs.items()}
        if observed != receipt["outputs"]:
            raise ValueError("host outputs differ from their captured build receipt")
