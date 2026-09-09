"""Package and admit host-owned archives separately from external dependencies."""

import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import shutil
from contextlib import contextmanager

from dependency_archive import write_archive
from dependency_artifacts import materialize, read_lock, unpack_verified
from host_notice_payload import NOTICE_FILES, SOURCE_KIND, validate_notices, validate_sources

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


def pack_host(target, source, output, root=ROOT, notices=None):
    """Capture only the declared host outputs and their source identity."""
    files = {}
    for name in HOST_FILES[target]:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or invalid GUI host output: {path}")
        files[f"targets/{target}/{name}"] = path.read_bytes()
    files["licenses/gui-host/LICENSE-GPUI"] = (root / "crates/gpui-host/LICENSE-GPUI").read_bytes()
    files["licenses/gui-host/LICENSE"] = (root / "LICENSE").read_bytes()
    fingerprint = source_fingerprint(root)
    if notices is not None:
        validate_notices(notices, target, files[f"targets/{target}/{HOST_FILES[target][0]}"], fingerprint,
                         root / "dependencies/gui-host-notices",
                         {name: files[f"targets/{target}/{name}"] for name in HOST_FILES[target]})
        for name in NOTICE_FILES:
            files["licenses/gui-host/" + name] = (notices / name).read_bytes()
    return write_archive(output, {
        "schema_version": 1, "name": "gui-host", "target": target,
        "source_fingerprint": fingerprint,
    }, files)


def validate_host(tree, target, expected_fingerprint, root=ROOT):
    """Check the verified archive's inventory and checkout compatibility."""
    manifest = json.loads((tree / "dependency.json").read_text())
    expected = {f"targets/{target}/{name}" for name in HOST_FILES[target]}
    expected.update({"licenses/gui-host/LICENSE-GPUI", "licenses/gui-host/LICENSE"})
    has_notices = "licenses/gui-host/NOTICE.json" in manifest["files"]
    if has_notices:
        expected.update("licenses/gui-host/" + name for name in NOTICE_FILES)
    if set(manifest["files"]) != expected:
        raise ValueError("incomplete or unexpected GUI host archive inventory")
    if manifest.get("source_fingerprint") != expected_fingerprint:
        raise ValueError("GUI host archive does not match this checkout's source inputs")
    if has_notices:
        validate_notices(tree / "licenses/gui-host", target,
                         (tree / "targets" / target / HOST_FILES[target][0]).read_bytes(), expected_fingerprint,
                         root / "dependencies/gui-host-notices",
                         {name: (tree / "targets" / target / name).read_bytes() for name in HOST_FILES[target]})


def validate_publication_notices(tree, source_tree=None, root=ROOT):
    """Require complete notices and their matching source companion for release."""
    if source_tree is None or not (tree / "licenses/gui-host/NOTICE.json").is_file():
        raise ValueError("complete transitive and toolchain notices and their source companion are required")
    dependency = json.loads((tree / "dependency.json").read_text())
    target = dependency["target"]
    host = (tree / "targets" / target / HOST_FILES[target][0]).read_bytes()
    manifest, data = validate_notices(tree / "licenses/gui-host", target, host, source_fingerprint(root),
                                      root / "dependencies/gui-host-notices",
                                      {name: (tree / "targets" / target / name).read_bytes() for name in HOST_FILES[target]})
    validate_sources(source_tree, manifest, data, host, (root / "Cargo.lock").read_bytes())


@contextmanager
def verified_hosts(lock_path, cache, root=ROOT):
    """Verify provenance and compatibility before exposing any prebuilt host."""
    lock = read_lock(lock_path)
    for identity, entry in lock["artifacts"].items():
        if (entry["name"] not in ("gui-host", SOURCE_KIND) or entry["target"] not in HOST_FILES
                or identity != entry["name"] + "-" + entry["target"]
                or entry["repository"] != REPOSITORY or entry["signer_workflow"] != WORKFLOW):
            raise ValueError("host lock must select this repository's GUI host producer")
    expected = source_fingerprint(root)
    hosts = {identity: entry for identity, entry in lock["artifacts"].items() if entry["name"] == "gui-host"}
    if not hosts or set(lock["artifacts"]) != set(hosts) | {SOURCE_KIND + "-" + e["target"] for e in hosts.values()}:
        raise ValueError("host lock must include exactly one source companion per host")
    with tempfile.TemporaryDirectory(prefix="signals-verified-hosts-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock_path, tuple(hosts), cache, destination)
        for identity, entry in hosts.items():
            validate_host(destination / identity, entry["target"], expected, root)
            notice = json.loads((destination / identity / "licenses/gui-host/NOTICE.json").read_text())
            companion = lock["artifacts"][SOURCE_KIND + "-" + entry["target"]]
            if (any(companion[k] != notice["source_companion"][k] for k in ("name", "target", "asset", "sha256", "size"))
                    or any(companion[k] != entry[k] for k in
                           ("repository", "release", "source_sha", "source_ref", "signer_workflow"))):
                raise ValueError("host source companion differs from its attested release identity")
        # Preserve source download identities without adding source archives to
        # the application's platform bundle or fetching them during every build.
        (destination / "dependencies.lock.json").write_text(json.dumps(lock, indent=2) + "\n")
        yield destination


def check_candidate(archive, target, roc, root=ROOT, source_companion=None):
    """Run native app specs using the exact extracted host archive candidate."""
    from build_gui import executable_name, host_target
    from gui_suite import examples
    from prepare_platforms import prepare_platform
    import spec_driver
    import toolchain

    if target != host_target():
        raise ValueError("host candidates must be checked on their native target")
    toolchain.verify_compiler(roc, toolchain.read_pin(root / "platform-gui/main.roc"))
    with tempfile.TemporaryDirectory(prefix="signals-host-candidate-") as temporary:
        stage = Path(temporary)
        extracted = stage / "candidate"
        unpack_verified(archive, {"name": "gui-host", "target": target}, extracted)
        validate_host(extracted, target, source_fingerprint(root), root)
        if source_companion is not None:
            sources = stage / "sources"
            unpack_verified(source_companion, {"name": SOURCE_KIND, "target": target}, sources)
            notice = json.loads((extracted / "licenses/gui-host/NOTICE.json").read_text())
            from dependency_artifacts import sha256
            if (sha256(source_companion) != notice["source_companion"]["sha256"]
                    or source_companion.stat().st_size != notice["source_companion"]["size"]):
                raise ValueError("candidate source companion differs from host notice binding")
            validate_publication_notices(extracted, sources, root)
        platform = stage / "platform-gui"
        prepare_platform(root / "platform-gui", platform)
        # External link inputs are tested with the host, but are not claimed as
        # host-owned payload. Their independent admission policies still apply.
        shutil.copytree(root / "platform-gui/targets" / target, platform / "targets" / target,
                        ignore=shutil.ignore_patterns(*HOST_FILES[target], "libhost.a", "host.lib"))
        if target == "arm64mac":
            shutil.copytree(root / "platform-gui/targets/macos-sysroot", platform / "targets/macos-sysroot")
        for name in HOST_FILES[target]:
            shutil.copyfile(extracted / "targets" / target / name, platform / "targets" / target / name)
        shutil.copytree(root / "examples-gui", stage / "examples-gui")
        shutil.copytree(root / "vendor", stage / "vendor")
        for app in examples(stage):
            executable = stage / executable_name(app.name)
            subprocess.run([roc, "build", "--no-cache", f"--target={target}",
                            f"--output={executable}", str(app / "main.roc")],
                           cwd=stage, check=True, timeout=180)
            results = spec_driver.run_suite(executable, app / "specs", jobs=1)
            spec_driver.print_summary(results)
            if not results or any(not result.passed for result in results):
                raise ValueError(f"host archive candidate failed {app.name} specs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(HOST_FILES), required=True)
    parser.add_argument("--source", type=Path, help="Directory containing freshly built host outputs")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--roc", help="Check the packaged candidate with this pinned Roc compiler")
    parser.add_argument("--notices", type=Path, help="Composed complete notice payload directory")
    parser.add_argument("--source-companion", type=Path, help="Verify this source companion with the native candidate")
    args = parser.parse_args()
    pack_host(args.target, args.source or ROOT / "platform-gui/targets" / args.target,
              args.output, notices=args.notices)
    if args.roc:
        check_candidate(args.output, args.target, str(Path(shutil.which(args.roc) or args.roc).resolve()),
                        source_companion=args.source_companion)
