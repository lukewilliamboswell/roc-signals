"""Package and admit host-owned archives separately from external dependencies."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from contextlib import contextmanager

from dependency_archive import write_archive
from dependency_artifacts import materialize, read_lock

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-signals"
WORKFLOW = REPOSITORY + "/.github/workflows/gui-hosts.yml"
HOST_FILES = {
    "x64glibc": ("libsignals_gpui_host.a", "libengine.a"),
    "arm64mac": ("libsignals_gpui_host.a", "libengine.a"),
    "x64win": ("signals_gpui_host.lib", "engine.lib", "signals.res"),
}
SOURCE_PATHS = (
    "src", "crates", "platform-gui", "platform-shared", "scripts", ".cargo",
    ".github/actions/setup-toolchain", ".github/workflows/gui-hosts.yml",
    "build.zig", "build.zig.zon", "Cargo.toml", "Cargo.lock", "dependencies.lock.json", "LICENSE",
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


def pack_host(target, source, output, root=ROOT):
    """Capture only the declared host outputs and their source identity."""
    files = {}
    for name in HOST_FILES[target]:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or invalid GUI host output: {path}")
        files[f"targets/{target}/{name}"] = path.read_bytes()
    files["licenses/gui-host/LICENSE-GPUI"] = (root / "crates/gpui-host/LICENSE-GPUI").read_bytes()
    files["licenses/gui-host/LICENSE"] = (root / "LICENSE").read_bytes()
    return write_archive(output, {
        "schema_version": 1, "name": "gui-host", "target": target,
        "source_fingerprint": source_fingerprint(root),
    }, files)


def validate_host(tree, target, expected_fingerprint):
    """Check the verified archive's inventory and checkout compatibility."""
    manifest = json.loads((tree / "dependency.json").read_text())
    expected = {f"targets/{target}/{name}" for name in HOST_FILES[target]}
    expected.update({"licenses/gui-host/LICENSE-GPUI", "licenses/gui-host/LICENSE"})
    if set(manifest["files"]) != expected:
        raise ValueError("incomplete or unexpected GUI host archive inventory")
    if manifest.get("source_fingerprint") != expected_fingerprint:
        raise ValueError("GUI host archive does not match this checkout's source inputs")


@contextmanager
def verified_hosts(lock_path, cache, root=ROOT):
    """Verify provenance and compatibility before exposing any prebuilt host."""
    lock = read_lock(lock_path)
    for identity, entry in lock["artifacts"].items():
        if (entry["name"] != "gui-host" or entry["target"] not in HOST_FILES
                or identity != "gui-host-" + entry["target"]
                or entry["repository"] != REPOSITORY or entry["signer_workflow"] != WORKFLOW):
            raise ValueError("host lock must select this repository's GUI host producer")
    expected = source_fingerprint(root)
    with tempfile.TemporaryDirectory(prefix="signals-verified-hosts-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock_path, tuple(lock["artifacts"]), cache, destination)
        for identity, entry in lock["artifacts"].items():
            validate_host(destination / identity, entry["target"], expected)
        yield destination
