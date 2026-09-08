#!/usr/bin/env python3
"""Prepare, validate and inspect immutable Signals release artifacts.

Published checks never rebind application dependencies. Candidate checks change
only temporary copies to use the exact archive served on loopback. Neither path
builds a replacement host or imports the checkout's browser executor.
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
from urllib.request import urlopen
import zipfile

import bundle_browser
from compiler_pins import read_pin, replace_pin
import known_failures
import test as driver
from toolchain import app_platform_span, replace_platform, validate_roots, verify_compiler

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-signals"
RELEASE_BASE = f"https://github.com/{REPOSITORY}/releases/download"
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_source_sha() -> str:
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True).strip():
        raise ValueError("release preparation requires a clean committed checkout")
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def public_examples():
    return tuple(example for example in driver.load_examples() if example.public)


def platform_url(source: str) -> str:
    span = app_platform_span(source)
    if span is None:
        raise ValueError("application has no platform header")
    return source[span[0]:span[1]]


def release_base(url: str) -> str:
    prefix = RELEASE_BASE + "/"
    if not url.startswith(prefix):
        raise ValueError(f"public application must pin an immutable Signals release URL: {url}")
    suffix = url[len(prefix):].split("/")
    if len(suffix) != 2 or not VERSION.fullmatch(suffix[0]) or not re.fullmatch(r"[A-Za-z0-9]+\.tar\.zst", suffix[1]):
        raise ValueError(f"invalid versioned platform URL: {url}")
    return url.rsplit("/", 1)[0]


def download(url: str, target: Path) -> None:
    with urlopen(url, timeout=120) as response, target.open("wb") as output:
        shutil.copyfileobj(response, output)


def extract(archive: Path, directory: Path) -> None:
    with zipfile.ZipFile(archive) as packed:
        for entry in packed.infolist():
            path = Path(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f"unsafe archive member: {entry.filename}")
        packed.extractall(directory)


def read_manifest(directory: Path) -> dict:
    manifest = json.loads((directory / "signals-release.json").read_text())
    if manifest.get("schema_version") != 1 or not VERSION.fullmatch(manifest["version"]):
        raise ValueError("unsupported release manifest")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["source_sha"]):
        raise ValueError("release must identify one source SHA")
    if set(manifest["assets"]) != {"platform", "browser", "starters"}:
        raise ValueError("release manifest must contain platform, browser and starters")
    for asset in manifest["assets"].values():
        if not re.fullmatch(r"[A-Za-z0-9._-]+", asset["name"]):
            raise ValueError("unsafe asset filename")
        if asset["url"] != f'{RELEASE_BASE}/{manifest["version"]}/{asset["name"]}':
            raise ValueError("asset URL disagrees with release identity")
        if digest(directory / asset["name"]) != asset["sha256"]:
            raise ValueError(f'asset digest mismatch: {asset["name"]}')
    if "site" in manifest:
        site = manifest["site"]
        if site["name"] != "signals-site.zip" or site["url"] != f'{RELEASE_BASE}/{manifest["version"]}/signals-site.zip' or digest(directory / site["name"]) != site["sha256"]:
            raise ValueError("site artifact identity mismatch")
    return manifest


@contextmanager
def fresh_cache(directory: Path):
    # Compiled modules and downloaded packages use distinct cache selectors.
    previous = {key: os.environ.get(key) for key in ("ROC_CACHE_DIR", "XDG_CACHE_HOME")}
    os.environ.update({key: str(directory) for key in previous})
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def check_apps(roc: str, examples: tuple, source_root: Path, runtime: Path, output: Path) -> None:
    ledger = known_failures.Ledger(known=frozenset())
    with fresh_cache(output / "cache"):
        driver.run_roc_checks(roc, examples, source_root=source_root, allow_release_platform_url=True)
        driver.run_roc_tests(roc, examples, source_root=source_root, allow_release_platform_url=True)
        driver.run_native_specs(roc, examples, source_root=source_root, bin_dir=output / "native",
                                allow_release_platform_url=True, ledger=ledger)
        wasm_dir = output / "wasm"
        wasm_dir.mkdir(parents=True)
        for example in examples:
            if not example.wasm:
                continue
            wasm = wasm_dir / f"{example.slug}.wasm"
            driver.run([roc, "build", "--target=wasm32", "--opt=size", "--no-cache",
                        f"--output={wasm}", source_root / example.source])
            driver.run(["node", ROOT / "scripts/browser/mount_wasm_example.mjs", wasm,
                        example.slug, "--runtime-dir", runtime])
    if not ledger.outcomes or not ledger.clean:
        raise ValueError("release native specs failed or no specs ran")


def runtime_from_artifacts(directory: Path, manifest: dict, output: Path) -> Path:
    extract(directory / manifest["assets"]["starters"]["name"], output)
    browser = output / "browser"
    with zipfile.ZipFile(directory / manifest["assets"]["browser"]["name"]) as runtime:
        for name in runtime.namelist():
            if runtime.read(name) != (browser / name).read_bytes():
                raise ValueError(f"starter runtime differs from browser archive: {name}")
    return browser


def check_candidate(directory: Path, roc: str) -> None:
    manifest = read_manifest(directory)
    verify_compiler(roc, manifest["compiler_pin"])
    with tempfile.TemporaryDirectory(prefix="signals-candidate-") as scratch:
        output = Path(scratch)
        sources = output / "starter"
        runtime = runtime_from_artifacts(directory, manifest, sources)
        with driver.BundleServer(directory) as server:
            local_url = f'http://127.0.0.1:{server.port}/{manifest["assets"]["platform"]["name"]}'
            for example in public_examples():
                path = sources / example.source
                source = path.read_text()
                if platform_url(source) != manifest["assets"]["platform"]["url"] or read_pin(path) != manifest["compiler_pin"]:
                    raise ValueError(f"starter header does not match release: {path}")
                path.write_text(replace_platform(source, local_url))
            check_apps(roc, public_examples(), sources, runtime, output / "checks")


def check_published(roc: str) -> None:
    examples = public_examples()
    pin = validate_roots()
    verify_compiler(roc, pin)
    urls = {platform_url((ROOT / example.source).read_text()) for example in examples}
    if len(urls) != 1:
        raise ValueError("public examples must use one reviewed supported platform release")
    url = urls.pop()
    base = release_base(url)
    before = {path: path.read_bytes() for example in examples for path in (ROOT / example.source.parent).rglob("*.roc")}
    with tempfile.TemporaryDirectory(prefix="signals-published-") as scratch:
        output = Path(scratch)
        download(base + "/signals-release.json", output / "signals-release.json")
        manifest = json.loads((output / "signals-release.json").read_text())
        for asset in [*manifest["assets"].values(), *([manifest["site"]] if "site" in manifest else [])]:
            if not re.fullmatch(r"[A-Za-z0-9._-]+", asset["name"]) or asset["url"] != base + "/" + asset["name"]:
                raise ValueError("published asset URL escaped its release")
            download(asset["url"], output / asset["name"])
        manifest = read_manifest(output)
        if manifest["assets"]["platform"]["url"] != url:
            raise ValueError("published manifest does not describe the committed platform URL")
        runtime = runtime_from_artifacts(output, manifest, output / "starter")
        check_apps(roc, examples, ROOT, runtime, output / "checks")
    if any(path.read_bytes() != data for path, data in before.items()):
        raise ValueError("published validation changed application source")


def check_downloads(directory: Path, roc: str) -> None:
    expected = read_manifest(directory)
    verify_compiler(roc, expected["compiler_pin"])
    with tempfile.TemporaryDirectory(prefix="signals-downloads-") as scratch:
        output = Path(scratch)
        download(f'{RELEASE_BASE}/{expected["version"]}/signals-release.json', output / "signals-release.json")
        if (output / "signals-release.json").read_bytes() != (directory / "signals-release.json").read_bytes():
            raise ValueError("published metadata differs from tested metadata")
        for asset in [*expected["assets"].values(), expected["site"]]:
            download(asset["url"], output / asset["name"])
        manifest = read_manifest(output)
        sources = output / "starter"
        runtime = runtime_from_artifacts(output, manifest, sources)
        check_apps(roc, public_examples(), sources, runtime, output / "checks")


def prepare(version: str, directory: Path, roc: str) -> None:
    source_sha = clean_source_sha()
    if not VERSION.fullmatch(version):
        raise ValueError("release version must be unprefixed SemVer without build metadata")
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("release output must be empty; retain previous artifacts for recovery")
    pin = validate_roots()
    verify_compiler(roc, pin)
    notes = ROOT / f"releases/{version}.md"
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f"finalize {notes} before preparing a release")
    directory.mkdir(parents=True, exist_ok=True)
    driver.run(["zig", "build", "build-test-hosts", "-Doptimize=ReleaseSmall"])
    environment = dict(os.environ, ROC_BIN=roc, BUNDLE_OUT_DIR=str(directory))
    subprocess.run([str(ROOT / "scripts/bundle.sh")], env=environment, cwd=ROOT, check=True)
    archives = list(directory.glob("*.tar.zst"))
    if len(archives) != 1:
        raise ValueError("expected exactly one platform archive")
    bundle_browser.bundle(directory / "signals-browser.zip")
    platform = archives[0]
    platform_ref = f"{RELEASE_BASE}/{version}/{platform.name}"
    with zipfile.ZipFile(directory / "signals-starters.zip", "w", compression=zipfile.ZIP_DEFLATED) as starter:
        with zipfile.ZipFile(directory / "signals-browser.zip") as browser:
            for name in browser.namelist():
                starter.writestr("browser/" + name, browser.read(name))
        runtime_names = set(bundle_browser.runtime_files())
        for name, data in bundle_browser.runtime_files(("example_tasks.mjs", "service_ops_charts.mjs")).items():
            if name not in runtime_names:
                starter.writestr("browser/" + name, data)
        for example in public_examples():
            for path in sorted((ROOT / example.source.parent).rglob("*")):
                if not path.is_file() or path.suffix not in {".roc", ".scm", ".md", ".toml"}:
                    continue
                data = path.read_bytes()
                if path == ROOT / example.source:
                    data = replace_platform(replace_pin(data.decode(), pin), platform_ref).encode()
                starter.writestr(path.relative_to(ROOT).as_posix(), data)
            page = '<!doctype html><meta charset="utf-8"><div id="app"></div><script type="module">\nimport { mountSignalsApp } from "../../browser/signals.mjs";\nimport { createPublicExampleTaskHandler } from "../../browser/example_tasks.mjs";\nimport { serviceOpsBehaviors } from "../../browser/service_ops_charts.mjs";\nawait mountSignalsApp({ root: document.getElementById("app"), wasmUrl: "./app.wasm", taskHandler: createPublicExampleTaskHandler(), behaviors: serviceOpsBehaviors });\n</script>\n'
            starter.writestr(str(example.source.parent / "index.html"), page)
        starter.writestr("README.md", f"# Roc Signals {version}\n\nInstall `{pin}` from https://github.com/roc-lang/nightlies/releases/tag/{pin}.\nRun `roc version` to verify it. Each examples/<name>/ folder includes the complete app and native specs.\n\nBuild for the browser: `roc build --target=wasm32 --opt=size --output=examples/<name>/app.wasm examples/<name>/main.roc`.\nServe this directory over HTTP (for example `python3 -m http.server`) and open examples/<name>/index.html.\n\nFor native specs, build with `roc build --target=<target> --output=app examples/<name>/main.roc`, then run `./app examples/<name>/specs/<case>.scm`. Targets: x64musl, arm64musl, x64mac, arm64mac.\nNo Zig build or repository checkout is required.\n")
    manifest = {"schema_version": 1, "version": version,
                "source_sha": source_sha,
                "compiler_pin": pin, "compiler_channel": "nightly-bootstrap", "assets": {}}
    for kind, path in {"platform": platform, "browser": directory / "signals-browser.zip", "starters": directory / "signals-starters.zip"}.items():
        manifest["assets"][kind] = {"name": path.name, "url": f"{RELEASE_BASE}/{version}/{path.name}", "sha256": digest(path)}
    (directory / "signals-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (directory / "release-notes.md").write_text(notes.read_text() + "\n## Validated artifacts\n\n" + f"Source: `{manifest['source_sha']}`. Compiler: `{pin}` (nightly bootstrap).\n\n" + "\n".join(f"- {kind}: {asset['url']} — SHA-256 `{asset['sha256']}`" for kind, asset in manifest["assets"].items()) + "\n")
    if clean_source_sha() != source_sha:
        raise ValueError("source changed during release preparation")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "check", "published", "verify", "downloads"])
    parser.add_argument("--version", default="0.2.0-rc1")
    parser.add_argument("--directory", type=Path, default=ROOT / ".release-out")
    parser.add_argument("--roc-bin", default=os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.command == "verify":
        print(json.dumps(read_manifest(directory), indent=2))
        return
    roc = driver.command_path(args.roc_bin)
    if args.command == "prepare":
        prepare(args.version, directory, roc)
    elif args.command == "check":
        check_candidate(directory, roc)
    elif args.command == "downloads":
        check_downloads(directory, roc)
    else:
        check_published(roc)


if __name__ == "__main__":
    main()
