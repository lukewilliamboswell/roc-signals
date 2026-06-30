#!/usr/bin/env python3
"""Standalone test driver for the Roc Signals platform."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
from pathlib import Path
import platform
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import tomllib
from dataclasses import dataclass


ROOT = Path(__file__).resolve().parent.parent
TEST_OUT = ROOT / ".test-out"
EXAMPLES_MANIFEST = ROOT / "www" / "data" / "examples.toml"
PLATFORM_HEADER_RE = re.compile(r'platform\s+"[^"]+"')


@dataclass(frozen=True)
class Example:
    slug: str
    title: str
    source: Path
    spec: Path | None
    public: bool
    wasm: bool
    native: bool
    bench: bool

    @property
    def exe_name(self) -> str:
        return f"signals-{self.slug}"


def load_examples() -> tuple[Example, ...]:
    with EXAMPLES_MANIFEST.open("rb") as f:
        manifest = tomllib.load(f)

    examples = []
    for raw in manifest.get("examples", []):
        spec = raw.get("spec")
        examples.append(
            Example(
                slug=str(raw["slug"]),
                title=str(raw.get("title", raw["slug"])),
                source=Path(str(raw["source"])),
                spec=Path(str(spec)) if spec else None,
                public=bool(raw.get("public", True)),
                wasm=bool(raw.get("wasm", True)),
                native=bool(raw.get("native", True)),
                bench=bool(raw.get("bench", False)),
            )
        )
    if not examples:
        raise SystemExit(f"no examples found in {EXAMPLES_MANIFEST}")
    return tuple(examples)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "suites",
        nargs="*",
        choices=("all", "zig", "browser", "roc-check", "wasm", "native", "bundle", "bench"),
        default=["all"],
        help="Suites to run. Defaults to all.",
    )
    parser.add_argument(
        "--roc-bin",
        default=os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc",
        help="Roc compiler path. Defaults to ROC_BIN, ROC, or roc from PATH.",
    )
    parser.add_argument(
        "--native",
        choices=("auto", "always", "never"),
        default="auto",
        help="Whether to run native executable specs. Auto runs them on macOS only.",
    )
    parser.add_argument(
        "--bundle",
        choices=("auto", "always", "never"),
        default="auto",
        help="Whether to build and test a bundle. Auto runs it on macOS only.",
    )
    parser.add_argument(
        "--keep-output",
        action="store_true",
        help="Keep .test-out after the run.",
    )
    return parser.parse_args()


def run(command: list[str | Path], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"\n==> {printable}", flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, env=env, check=True)


def command_path(value: str) -> str:
    path = Path(value)
    if len(path.parts) == 1:
        found = shutil.which(value)
        if found is not None:
            return found
        raise SystemExit(f"missing Roc compiler: {value}")
    if path.exists() and os.access(path, os.X_OK):
        return str(path)
    raise SystemExit(f"missing Roc compiler: {value}")


def ensure_clean_output(keep_output: bool) -> None:
    if keep_output:
        TEST_OUT.mkdir(exist_ok=True)
        return
    if TEST_OUT.exists():
        shutil.rmtree(TEST_OUT)
    TEST_OUT.mkdir()


def build_hosts() -> None:
    run(["zig", "build", "build-test-hosts"])


def run_zig_suite() -> None:
    run(["zig", "build", "test"])


def run_browser_suite() -> None:
    run(["zig", "build", "run-test-browser"])


def run_roc_checks(roc_bin: str, examples: tuple[Example, ...]) -> None:
    for example in examples:
        run([roc_bin, "check", example.source])


def build_wasm_apps(roc_bin: str, examples: tuple[Example, ...]) -> None:
    wasm_dir = TEST_OUT / "wasm"
    wasm_dir.mkdir(parents=True, exist_ok=True)
    for example in examples:
        if not example.wasm:
            continue
        output = wasm_dir / f"{example.slug}.wasm"
        run(
            [
                roc_bin,
                "build",
                "--target=wasm32",
                "--opt=size",
                "--no-cache",
                f"--output={output}",
                example.source,
            ]
        )
        run(["node", "scripts/browser/mount_wasm_example.mjs", output, example.slug])


def should_run_hosted(mode: str) -> bool:
    if mode == "always":
        return True
    if mode == "never":
        return False
    return platform.system() == "Darwin"


def native_exe_path(bin_dir: Path, exe_name: str) -> Path:
    suffix = ".exe" if platform.system() == "Windows" else ""
    return bin_dir / f"{exe_name}{suffix}"


def roc_native_target() -> str:
    if platform.system() != "Darwin":
        raise SystemExit("native specs require the platform's macOS targets")

    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64mac"
    if machine in {"x86_64", "amd64"}:
        return "x64mac"
    raise SystemExit(f"unsupported macOS architecture for native specs: {platform.machine()}")


def run_native_specs(
    roc_bin: str,
    examples: tuple[Example, ...],
    *,
    source_root: Path = ROOT,
    bin_dir: Path = TEST_OUT / "bin",
) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    target = roc_native_target()
    for example in examples:
        if not example.native:
            continue
        if example.spec is None:
            raise SystemExit(f"{example.slug} is native but has no spec")
        source = source_root / example.source
        spec = source_root / example.spec
        exe = native_exe_path(bin_dir, example.exe_name)
        run([roc_bin, "build", f"--target={target}", "--opt=dev", f"--output={exe}", source])
        run([exe, spec])


def run_benchmarks(roc_bin: str, examples: tuple[Example, ...]) -> None:
    bin_dir = TEST_OUT / "bench-bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    target = roc_native_target()
    for example in examples:
        if not example.bench:
            continue
        if example.spec is None:
            raise SystemExit(f"{example.slug} is benchmarked but has no spec")
        exe = native_exe_path(bin_dir, f"{example.exe_name}-bench")
        run([roc_bin, "build", f"--target={target}", "--opt=speed", f"--output={exe}", example.source])
        run(
            [
                exe,
                "--bench-app",
                "--bench-name",
                example.exe_name,
                "--bench-iterations",
                "20",
                "--bench-samples",
                "1",
                example.spec,
            ]
        )


def rewrite_platform_headers(root: Path, platform_ref: str) -> None:
    replacement = f'platform "{platform_ref}"'
    for source in sorted(root.rglob("*.roc")):
        text = source.read_text(encoding="utf-8")
        updated, count = PLATFORM_HEADER_RE.subn(replacement, text, count=1)
        if count != 0:
            source.write_text(updated, encoding="utf-8")


def rewrite_examples_for_bundle(bundle_url: str, dest_root: Path) -> None:
    examples_dest = dest_root / "examples"
    shutil.copytree(ROOT / "examples", examples_dest, dirs_exist_ok=True)
    rewrite_platform_headers(examples_dest, bundle_url)


class BundleServer:
    def __init__(self, directory: Path):
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
        self.httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return int(self.httpd.server_address[1])

    def __enter__(self) -> "BundleServer":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


def bundle_platform(roc_bin: str) -> Path:
    env = os.environ.copy()
    env["ROC_BIN"] = roc_bin
    bundle_out = TEST_OUT / "bundles"
    bundle_out.mkdir(parents=True, exist_ok=True)
    env["BUNDLE_OUT_DIR"] = str(bundle_out)
    result = subprocess.run(
        [str(ROOT / "scripts" / "bundle.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=True,
    )
    print(result.stdout, end="")
    for line in result.stdout.splitlines():
        if line.startswith("Created:"):
            return Path(line.split(":", 1)[1].strip())
    raise SystemExit("scripts/bundle.sh did not print a Created: line")


def run_bundle_suite(roc_bin: str, examples: tuple[Example, ...]) -> None:
    bundle = bundle_platform(roc_bin)
    with BundleServer(bundle.resolve().parent) as server:
        bundle_url = f"http://127.0.0.1:{server.port}/{bundle.name}"
        print(f"\nTesting bundled platform: {bundle_url}")
        source_root = TEST_OUT / "bundle-source"
        rewrite_examples_for_bundle(bundle_url, source_root)
        run_native_specs(roc_bin, examples, source_root=source_root, bin_dir=TEST_OUT / "bundle-bin")


def main() -> int:
    args = parse_args()
    examples = load_examples()
    suites = set(args.suites)
    if "all" in suites:
        suites = {"zig", "browser", "roc-check", "wasm", "native", "bundle", "bench"}

    roc_bin = command_path(args.roc_bin)
    ensure_clean_output(args.keep_output)

    build_hosts()

    if "zig" in suites:
        run_zig_suite()
    if "browser" in suites:
        run_browser_suite()
    if "roc-check" in suites:
        run_roc_checks(roc_bin, examples)
    if "wasm" in suites:
        build_wasm_apps(roc_bin, examples)

    if "native" in suites:
        if should_run_hosted(args.native):
            run_native_specs(roc_bin, examples)
        else:
            print("\nSkipping native specs: platform manifest exposes macOS native targets only.")

    if "bundle" in suites:
        if should_run_hosted(args.bundle):
            run_bundle_suite(roc_bin, examples)
        else:
            print("\nSkipping bundle executable tests: platform manifest exposes macOS native targets only.")

    if "bench" in suites:
        if should_run_hosted(args.native):
            run_benchmarks(roc_bin, examples)
        else:
            print("\nSkipping benchmarks: platform manifest exposes macOS native targets only.")

    if not args.keep_output and TEST_OUT.exists():
        shutil.rmtree(TEST_OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
