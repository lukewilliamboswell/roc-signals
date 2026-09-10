#!/usr/bin/env python3
"""Prepare, smoke-test, verify, and publish one combined platform release.

The release contains exactly two Roc platform bundles plus one example-source
archive. Host engines and external linker inputs are downloaded from immutable
locks and verified by content hash; this module never builds them.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

import bundle_browser
from build_gui import build_environment, executable_name, host_target
from compiler_pins import read_pin, replace_pin
from dependency_artifacts import read_lock
import gui_smoke
from gui_suite import examples as gui_examples
import spec_driver
import test as driver
from toolchain import app_platform_span, replace_platform, validate_roots, verify_compiler

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-signals"
RELEASE_BASE = f"https://github.com/{REPOSITORY}/releases/download"
MANIFEST = "signals-release.json"
EXAMPLES = "signals-examples.zip"
MAX_TRANSITIVE_MB = 512
VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path: Path, version: str) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"release asset is not a regular file: {path}")
    return {
        "name": path.name,
        "url": f"{RELEASE_BASE}/{version}/{path.name}",
        "sha256": digest(path),
        "size": path.stat().st_size,
    }


def clean_source_sha() -> str:
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True
    ).strip()
    if status:
        raise ValueError("release preparation requires a clean committed checkout")
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def web_examples():
    return tuple(example for example in driver.load_examples() if example.public)


def platform_url(source: str) -> str:
    span = app_platform_span(source)
    if span is None:
        raise ValueError("application has no platform header")
    return source[span[0]:span[1]]


def tracked_files(directory: Path) -> tuple[Path, ...]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z", "--", str(directory.relative_to(ROOT))], cwd=ROOT
    )
    files = tuple(ROOT / name.decode() for name in output.rstrip(b"\0").split(b"\0") if name)
    if not files or any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError(f"example inventory must contain only tracked regular files: {directory}")
    return files


def zip_entry(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = 0o100644 << 16
    archive.writestr(entry, data)


def write_examples(path: Path, pin: str, web_url: str, gui_url: str) -> None:
    with zipfile.ZipFile(path, "x") as archive:
        runtime = bundle_browser.runtime_files(("example_tasks.mjs", "service_ops_charts.mjs"))
        for name, data in sorted(runtime.items()):
            zip_entry(archive, "browser/" + name, data)
        for example in web_examples():
            root = ROOT / example.source.parent
            for source in tracked_files(root):
                data = source.read_bytes()
                if source == ROOT / example.source:
                    data = replace_platform(replace_pin(data.decode(), pin), web_url).encode()
                zip_entry(archive, source.relative_to(ROOT).as_posix(), data)
            page = (
                '<!doctype html><meta charset="utf-8"><div id="app"></div>'
                '<script type="module">\nimport { mountSignalsApp } from "../../browser/signals.mjs";\n'
                'import { createPublicExampleTaskHandler } from "../../browser/example_tasks.mjs";\n'
                'import { serviceOpsBehaviors } from "../../browser/service_ops_charts.mjs";\n'
                'await mountSignalsApp({ root: document.getElementById("app"), wasmUrl: "./app.wasm", '
                'taskHandler: createPublicExampleTaskHandler(), behaviors: serviceOpsBehaviors });\n</script>\n'
            )
            zip_entry(archive, (example.source.parent / "index.html").as_posix(), page.encode())
        for app in gui_examples():
            for source in tracked_files(app):
                data = source.read_bytes()
                if source == app / "main.roc":
                    data = replace_platform(replace_pin(data.decode(), pin), gui_url).encode()
                zip_entry(archive, source.relative_to(ROOT).as_posix(), data)
        for source in tracked_files(ROOT / "vendor/unicode"):
            zip_entry(archive, source.relative_to(ROOT).as_posix(), source.read_bytes())
        readme = (
            "# Roc Signals release examples\n\n"
            "`examples-web/` and `examples-gui/` are distinct applications using distinct platform APIs. "
            "Their headers pin the two platform assets from the same immutable release.\n"
        )
        zip_entry(archive, "README.md", readme.encode())


def extract_examples(path: Path, destination: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        seen = set()
        for entry in archive.infolist():
            name = Path(entry.filename)
            if (entry.filename in seen or name.is_absolute() or ".." in name.parts
                    or "\\" in entry.filename or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError(f"unsafe example archive member: {entry.filename}")
            seen.add(entry.filename)
        archive.extractall(destination)


def read_manifest(directory: Path) -> dict:
    manifest = json.loads((directory / MANIFEST).read_text())
    if (manifest.get("schema_version") != 2 or not VERSION.fullmatch(manifest.get("version", ""))
            or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("source_sha", ""))):
        raise ValueError("unsupported combined platform release manifest")
    if manifest.get("max_transitive_mb") != MAX_TRANSITIVE_MB:
        raise ValueError("release package budget differs from the reviewed RC policy")
    if manifest.get("provenance") != {
        "signer_workflow": REPOSITORY + "/.github/workflows/release.yml",
        "source_ref": "refs/heads/main",
    }:
        raise ValueError("unsupported combined release provenance policy")
    assets = manifest.get("assets", {})
    if set(assets) != {"web", "gui", "examples"}:
        raise ValueError("release must contain web, GUI, and example assets")
    if assets["examples"]["name"] != EXAMPLES:
        raise ValueError("release example archive has the wrong identity")
    if assets["web"]["name"] == assets["gui"]["name"]:
        raise ValueError("web and GUI must remain distinct platform packages")
    expected = {MANIFEST, "release-notes.md"}
    for kind, asset in assets.items():
        name = asset.get("name", "")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            raise ValueError("unsafe release asset name")
        path = directory / name
        if asset != record(path, manifest["version"]):
            raise ValueError(f"{kind} release asset differs from its manifest")
        expected.add(name)
    if {path.name for path in directory.iterdir()} != expected:
        raise ValueError("combined release contains an unexpected asset")
    inputs = manifest.get("inputs", {})
    if set(inputs) != {"web_hosts", "gui_hosts", "linker_inputs"}:
        raise ValueError("release input locks are incomplete")
    return manifest


@contextmanager
def fresh_cache(directory: Path):
    previous = {key: os.environ.get(key) for key in ("ROC_CACHE_DIR", "XDG_CACHE_HOME")}
    os.environ.update({key: str(directory / key.lower()) for key in previous})
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def roc_run(roc: str, action: str, source: Path, *arguments, cwd: Path | None = None,
            env: dict | None = None) -> None:
    driver.run(
        [roc, action, *arguments, source, f"--max-transitive-mb={MAX_TRANSITIVE_MB}"],
        cwd=cwd or source.parent,
        env=env,
    )


def require_headers(root: Path, manifest: dict) -> None:
    pin = manifest["compiler_pin"]
    for example in web_examples():
        source = root / example.source
        if read_pin(source) != pin or platform_url(source.read_text()) != manifest["assets"]["web"]["url"]:
            raise ValueError(f"web example header differs from the release: {example.source}")
    for app in gui_examples():
        source = root / app.relative_to(ROOT) / "main.roc"
        if read_pin(source) != pin or platform_url(source.read_text()) != manifest["assets"]["gui"]["url"]:
            raise ValueError(f"GUI example header differs from the release: {source.relative_to(root)}")


def bind_local_headers(root: Path, manifest: dict, origin: str) -> None:
    for example in web_examples():
        source = root / example.source
        source.write_text(replace_platform(source.read_text(), origin + "/" + manifest["assets"]["web"]["name"]))
    for app in gui_examples():
        source = root / app.relative_to(ROOT) / "main.roc"
        source.write_text(replace_platform(source.read_text(), origin + "/" + manifest["assets"]["gui"]["name"]))


def check_web(roc: str, root: Path, output: Path) -> None:
    target = driver.native_target_for_host()
    for example in web_examples():
        source = root / example.source
        roc_run(roc, "check", source)
        roc_run(roc, "test", source)
        wasm = output / "wasm" / (example.slug + ".wasm")
        wasm.parent.mkdir(parents=True, exist_ok=True)
        roc_run(roc, "build", source, "--target=wasm32", "--opt=size", "--no-cache", f"--output={wasm}")
        driver.run(["node", ROOT / "scripts/browser/mount_wasm_example.mjs", wasm,
                    example.slug, "--runtime-dir", root / "browser"])
        if target is None or not example.native or driver.should_skip_native_example(target, example):
            continue
        executable = output / "web-native" / driver.native_exe_path(Path(), example.exe_name).name
        executable.parent.mkdir(parents=True, exist_ok=True)
        roc_run(roc, "build", source, f"--target={target}", "--opt=dev", "--no-cache",
                f"--output={executable}")
        results = spec_driver.run_suite(executable, root / example.specs, jobs=2, timeout_seconds=30)
        spec_driver.print_summary(results)
        if any(not result.passed for result in results):
            raise ValueError(f"web release specs failed: {example.slug}")


def check_gui(roc: str, root: Path, output: Path) -> None:
    target = host_target()
    if target is None:
        raise ValueError("combined release smoke requires a supported native GUI runner")
    binaries = output / "gui"
    binaries.mkdir(parents=True, exist_ok=True)
    environment = build_environment()
    for app in gui_examples():
        released = root / app.relative_to(ROOT)
        source = released / "main.roc"
        roc_run(roc, "check", source, env=environment)
        roc_run(roc, "test", source, env=environment)
        executable = binaries / executable_name(app.name)
        roc_run(roc, "build", source, f"--target={target}", "--opt=dev", "--no-cache",
                f"--output={executable}", env=environment)
        results = spec_driver.run_suite(executable, released / "specs", jobs=2, timeout_seconds=30)
        spec_driver.print_summary(results)
        if any(not result.passed for result in results):
            raise ValueError(f"GUI release specs failed: {app.name}")
    if os.environ.get("SIGNALS_WAYLAND_SMOKE") == "1":
        gui_smoke.wayland(binaries)
    else:
        gui_smoke.run(binaries, environment)


def prepare(version: str, directory: Path, roc: str, web_host_lock: Path, gui_host_lock: Path) -> None:
    source_sha = clean_source_sha()
    if not VERSION.fullmatch(version):
        raise ValueError("release version must be unprefixed SemVer without build metadata")
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("release output must be empty")
    pin = validate_roots()
    verify_compiler(roc, pin)
    notes = ROOT / f"releases/{version}.md"
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f"finalize {notes} before preparing a release")
    locks = {
        "web_hosts": read_lock(web_host_lock),
        "gui_hosts": read_lock(gui_host_lock),
        "linker_inputs": read_lock(ROOT / "dependencies.lock.json"),
    }
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="signals-platform-release-", dir=directory.parent) as temporary:
        bundles = Path(temporary) / "bundles"
        environment = dict(os.environ, ROC_BIN=roc)
        subprocess.run([
            os.fspath(ROOT / "scripts/bundle.sh"), "--package", "all", "--no-build",
            "--prebuilt-web-host-lock", os.fspath(web_host_lock),
            "--prebuilt-host-lock", os.fspath(gui_host_lock),
            "--output-dir", os.fspath(bundles),
        ], cwd=ROOT, env=environment, check=True)
        bundle_manifest = json.loads((bundles / "bundles.json").read_text())
        if set(bundle_manifest) != {"web", "gui"}:
            raise ValueError("bundler did not produce exactly web and GUI packages")
        paths = {}
        for kind in ("web", "gui"):
            source = bundles / bundle_manifest[kind]
            if source.suffixes[-2:] != [".tar", ".zst"] or source.parent != bundles / kind:
                raise ValueError("unexpected Roc bundle output")
            destination = directory / source.name
            shutil.copyfile(source, destination)
            paths[kind] = destination
    web_url = f"{RELEASE_BASE}/{version}/{paths['web'].name}"
    gui_url = f"{RELEASE_BASE}/{version}/{paths['gui'].name}"
    write_examples(directory / EXAMPLES, pin, web_url, gui_url)
    manifest = {
        "schema_version": 2,
        "version": version,
        "source_sha": source_sha,
        "compiler_pin": pin,
        "max_transitive_mb": MAX_TRANSITIVE_MB,
        "assets": {
            "web": record(paths["web"], version),
            "gui": record(paths["gui"], version),
            "examples": record(directory / EXAMPLES, version),
        },
        "inputs": locks,
        "provenance": {
            "signer_workflow": REPOSITORY + "/.github/workflows/release.yml",
            "source_ref": "refs/heads/main",
        },
    }
    (directory / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n")
    assets = "\n".join(
        f"- {kind}: {item['url']} — SHA-256 `{item['sha256']}`"
        for kind, item in manifest["assets"].items()
    )
    (directory / "release-notes.md").write_text(
        notes.read_text().rstrip() + "\n\n## Tested assets\n\n" + assets + "\n\n"
        f"Example builds use `--max-transitive-mb={MAX_TRANSITIVE_MB}` for this fat RC.\n"
    )
    read_manifest(directory)
    if clean_source_sha() != source_sha:
        raise ValueError("source changed during release preparation")


def check(directory: Path, roc: str) -> None:
    manifest = read_manifest(directory)
    verify_compiler(roc, manifest["compiler_pin"])
    with tempfile.TemporaryDirectory(prefix="signals-release-smoke-") as temporary:
        root = Path(temporary) / "examples"
        extract_examples(directory / EXAMPLES, root)
        require_headers(root, manifest)
        with driver.BundleServer(directory) as server:
            bind_local_headers(root, manifest, f"http://127.0.0.1:{server.port}")
            with fresh_cache(Path(temporary) / "cache"):
                check_web(roc, root, Path(temporary) / "outputs")
                check_gui(roc, root, Path(temporary) / "outputs")


def require_publish_context(manifest: dict) -> None:
    expected = {
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_SHA": manifest["source_sha"],
    }
    if any(os.environ.get(key) != value for key, value in expected.items()):
        raise ValueError("release publication requires the tested explicit main dispatch")
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != manifest["source_sha"]:
        raise ValueError("release publication checkout differs from tested source")


def publish(directory: Path) -> None:
    manifest = read_manifest(directory)
    require_publish_context(manifest)
    tag = manifest["version"]
    tags = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}",
    ], text=True))
    if any(item["ref"] == "refs/tags/" + tag for item in tags):
        raise ValueError("release tag already exists; inspect the original publication")
    assets = [directory / item["name"] for item in manifest["assets"].values()]
    assets.append(directory / MANIFEST)
    subprocess.run([
        "gh", "release", "create", tag, *map(str, assets), "--repo", REPOSITORY,
        "--target", manifest["source_sha"], "--title", f"Roc Signals {tag}",
        "--notes-file", directory / "release-notes.md", "--prerelease", "--latest=false",
    ], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "check", "verify", "publish"))
    parser.add_argument("--version", default="0.2.0-rc3")
    parser.add_argument("--directory", type=Path, default=ROOT / ".release-out")
    parser.add_argument("--roc-bin", default=os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc")
    parser.add_argument("--web-host-lock", type=Path, default=ROOT / "web-host.lock.json")
    parser.add_argument("--gui-host-lock", type=Path, default=ROOT / "gui-host.lock.json")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.command == "verify":
        print(json.dumps(read_manifest(directory), indent=2))
        return
    if args.command == "publish":
        publish(directory)
        return
    roc = driver.command_path(args.roc_bin)
    if args.command == "prepare":
        prepare(args.version, directory, roc, args.web_host_lock.resolve(), args.gui_host_lock.resolve())
    else:
        check(directory, roc)


if __name__ == "__main__":
    main()
