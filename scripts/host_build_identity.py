"""Identify committed host build inputs and every host-owned output."""

import hashlib
import json
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
    "src", "crates", "platform-gui", "platform-shared", "scripts", ".cargo",
    "dependencies/gui-host-notices",
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
    if outputs is not None:
        observed = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                    for name, data in outputs.items()}
        if observed != receipt["outputs"]:
            raise ValueError("host outputs differ from their captured build receipt")
