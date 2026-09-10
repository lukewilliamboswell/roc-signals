"""Package and admit the web platform's prebuilt native and Wasm hosts."""

import argparse
import hashlib
import json
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile

from dependency_archive import write_archive
from dependency_artifacts import materialize, read_lock

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-signals"
WORKFLOW = REPOSITORY + "/.github/workflows/web-hosts.yml"
OUTPUTS = {target: ("host.wasm" if target == "wasm32" else "libhost.a")
           for target in ("x64mac", "arm64mac", "x64musl", "arm64musl", "wasm32")}
IDENTITIES = tuple("web-host-" + target for target in OUTPUTS)
SOURCE_PATHS = ("src/native_host.zig", "src/wasm_host.zig", "src/signals", "build.zig", "build.zig.zon")


def source_fingerprint(root=ROOT):
    """Hash only clean committed files that can change web host bytes."""
    changed = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", *SOURCE_PATHS], cwd=root).returncode
    untracked = subprocess.check_output([
        "git", "ls-files", "--others", "--exclude-standard", "-z", "--", *SOURCE_PATHS,
    ], cwd=root)
    if changed or untracked:
        raise ValueError("prebuilt web hosts require clean committed host inputs")
    tree = subprocess.check_output([
        "git", "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *SOURCE_PATHS,
    ], cwd=root)
    if not tree:
        raise ValueError("web host source inventory is empty")
    return hashlib.sha256(tree).hexdigest()


def pack(target, source, output, root=ROOT):
    """Capture exactly one target's host output and the project license."""
    if target not in OUTPUTS:
        raise ValueError("unsupported web host target")
    name = "targets/" + target + "/" + OUTPUTS[target]
    path = source / name
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or invalid web host output: {path}")
    files = {name: path.read_bytes()}
    files["licenses/web-host/LICENSE"] = (root / "LICENSE").read_bytes()
    return write_archive(output, {"schema_version": 1, "name": "web-host", "target": target,
                                  "input_fingerprint": source_fingerprint(root)}, files)


def validate(tree, target, expected_fingerprint):
    """Reject source drift, extra outputs, and incomplete host archives."""
    manifest = json.loads((tree / "dependency.json").read_text())
    expected = {"targets/" + target + "/" + OUTPUTS[target], "licenses/web-host/LICENSE"}
    if (manifest.get("name") != "web-host" or manifest.get("target") != target
            or manifest.get("input_fingerprint") != expected_fingerprint
            or set(manifest.get("files", {})) != expected):
        raise ValueError("web host archive differs from its input identity or exact inventory")


@contextmanager
def verified_hosts(lock_path, cache, root=ROOT):
    """Verify locked bytes and current input compatibility before staging hosts."""
    lock = read_lock(lock_path)
    if set(lock["artifacts"]) != set(IDENTITIES):
        raise ValueError("web host lock must select the complete five-target host set")
    fingerprint = source_fingerprint(root)
    for identity, target in zip(IDENTITIES, OUTPUTS):
        entry = lock["artifacts"][identity]
        if (entry["name"] != "web-host" or entry["target"] != target
                or entry["repository"] != REPOSITORY or entry["signer_workflow"] != WORKFLOW
                or entry.get("input_fingerprint") != fingerprint):
            raise ValueError("web host lock does not match this checkout's host inputs")
    with tempfile.TemporaryDirectory(prefix="signals-verified-web-hosts-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock_path, IDENTITIES, cache, destination)
        for identity, target in zip(IDENTITIES, OUTPUTS):
            validate(destination / identity, target, fingerprint)
        yield destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "platform-web")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for identity, target in zip(IDENTITIES, OUTPUTS):
        pack(target, args.source, args.output / (identity + ".tar"))
