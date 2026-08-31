#!/usr/bin/env python3
"""Standalone test driver for the Roc Signals platform."""

from __future__ import annotations

import argparse
import functools
import hashlib
import http.server
import json
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
from urllib.parse import urlparse

import known_failures
import spec_driver


ROOT = Path(__file__).resolve().parent.parent
TEST_OUT = ROOT / ".test-out"
EXAMPLES_MANIFEST = ROOT / "www" / "data" / "examples.toml"
PLATFORM_HEADER_RE = re.compile(r'platform\s+"[^"]+"')
PLATFORM_HEADER_CAPTURE_RE = re.compile(r'platform\s+"([^"]+)"')
URL_SCHEMES = {"http", "https"}
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
MUSL_NATIVE_SKIPS: dict[str, str] = {}
LINUX_WASM_SKIPS: dict[str, str] = {}
FAULT_CAMPAIGN_EXAMPLES = {"markdown-elem", "when-each-dispose"}


@dataclass(frozen=True)
class Example:
    slug: str
    title: str
    source: Path
    specs: Path | None
    public: bool
    wasm: bool
    native: bool
    bench: bool
    expect_mount_error: str | None

    @property
    def exe_name(self) -> str:
        return f"signals-{self.slug}"


@dataclass(frozen=True)
class BenchmarkCase:
    id: str
    spec: Path
    warmup_iterations: int
    native_iterations: int
    native_samples: int
    serial_native_spec: bool
    native_spec_timeout_seconds: float | None


def load_benchmark_cases(example: Example, source_root: Path) -> tuple[BenchmarkCase, ...] | None:
    """Load an optional per-fixture benchmark contract."""
    manifest_path = source_root / example.source.parent / "benchmarks.toml"
    if not manifest_path.is_file():
        return None
    with manifest_path.open("rb") as f:
        manifest = tomllib.load(f)
    if manifest.get("schema_version") != 1:
        raise SystemExit(f"unsupported benchmark manifest schema: {manifest_path}")

    cases: list[BenchmarkCase] = []
    seen: set[str] = set()
    for raw in manifest.get("operations", []):
        case_id = str(raw["id"])
        if case_id in seen:
            raise SystemExit(f"duplicate benchmark operation {case_id!r} in {manifest_path}")
        seen.add(case_id)
        warmup = int(raw["warmup_iterations"])
        iterations = int(raw["native_iterations"])
        samples = int(raw["native_samples"])
        if warmup < 0 or iterations <= 0 or samples <= 0:
            raise SystemExit(f"invalid benchmark counts for {case_id!r} in {manifest_path}")
        spec = example.source.parent / Path(str(raw["spec"]))
        if not (source_root / spec).is_file():
            raise SystemExit(f"benchmark operation {case_id!r} references missing spec {spec}")
        timeout = float(raw["native_spec_timeout_seconds"]) if "native_spec_timeout_seconds" in raw else None
        if timeout is not None and timeout <= 0:
            raise SystemExit(f"invalid native spec timeout for {case_id!r} in {manifest_path}")
        cases.append(BenchmarkCase(case_id, spec, warmup, iterations, samples, bool(raw.get("serial_native_spec", False)), timeout))
    if not cases:
        raise SystemExit(f"benchmark manifest has no operations: {manifest_path}")
    return tuple(cases)


def load_examples() -> tuple[Example, ...]:
    with EXAMPLES_MANIFEST.open("rb") as f:
        manifest = tomllib.load(f)

    examples = []
    for raw in manifest.get("examples", []):
        specs = raw.get("specs")
        examples.append(
            Example(
                slug=str(raw["slug"]),
                title=str(raw.get("title", raw["slug"])),
                source=Path(str(raw["source"])),
                specs=Path(str(specs)) if specs else None,
                public=bool(raw.get("public", True)),
                wasm=bool(raw.get("wasm", True)),
                native=bool(raw.get("native", True)),
                bench=bool(raw.get("bench", False)),
                expect_mount_error=str(raw["expect_mount_error"]) if "expect_mount_error" in raw else None,
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
        choices=("all", "zig", "fuzz", "browser", "roc-check", "roc-test", "wasm", "wasm-bench", "native", "fault", "bundle", "bench"),
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
        help="Whether to run native executable specs. Auto runs them on macOS and Linux.",
    )
    parser.add_argument(
        "--bundle",
        choices=("auto", "always", "never"),
        default="auto",
        help="Whether to build and test a bundle. Auto runs it on macOS and Linux.",
    )
    parser.add_argument(
        "--bundle-ref",
        default=os.environ.get("BUNDLE_REF"),
        help="Existing bundle path or URL to test for the bundle suite. Defaults to building one.",
    )
    parser.add_argument(
        "--allow-release-platform-url",
        action="store_true",
        help=(
            "Allow tests to run against a non-local platform URL. Intended only for release "
            "verification; development tests should use a local platform path or bundle file."
        ),
    )
    parser.add_argument(
        "--keep-output",
        action="store_true",
        help="Keep .test-out after the run.",
    )
    parser.add_argument(
        "--jobs",
        type=spec_driver.parse_jobs,
        default=None,
        metavar="auto|N",
        help="Concurrent ordinary native spec workers. Designated large specs run serially.",
    )
    parser.add_argument(
        "--spec-filter",
        action="append",
        default=[],
        metavar="GLOB",
        help="Run native specs whose suite-relative path matches GLOB. Repeatable.",
    )
    parser.add_argument("--shard", type=spec_driver.parse_shard, metavar="CURRENT/TOTAL")
    parser.add_argument("--fail-fast", action="store_true", help="Stop scheduling specs after the first failure.")
    parser.add_argument(
        "--known-failures",
        default=str(ROOT / "test" / "known-failures.txt"),
        metavar="PATH",
        help="Ratchet file of specs and wasm mounts that are expected to fail. Unlisted failures and listed passes both fail the run.",
    )
    parser.add_argument(
        "--update-known-failures",
        action="store_true",
        help="Delete entries from the known-failures file that passed in this run. Never adds entries.",
    )
    parser.add_argument("--spec-timeout", type=float, default=30.0, metavar="SECONDS")
    parser.add_argument("--bench-case", action="append", default=[], metavar="GLOB", help="Select Wasm benchmark cases. Repeatable.")
    parser.add_argument("--bench-warmups", type=int, default=1, metavar="N", help="Complete warm-up passes for wasm-bench.")
    parser.add_argument("--bench-iterations", type=int, default=20, metavar="N", help="Fresh paired iterations per Wasm benchmark sample.")
    parser.add_argument("--bench-samples", type=int, default=7, metavar="N", help="Wasm benchmark samples per case.")
    parser.add_argument("--bench-app-opt", choices=("size", "speed"), default="size", help="Roc Wasm application optimization mode.")
    return parser.parse_args()


def run(command: list[str | Path], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"\n==> {printable}", flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, env=env, check=True)


def is_url_ref(value: str) -> bool:
    return urlparse(value).scheme.lower() in URL_SCHEMES


def is_local_url_ref(value: str) -> bool:
    if not is_url_ref(value):
        return False
    parsed = urlparse(value)
    return parsed.hostname in LOOPBACK_HOSTS


def is_release_platform_url(value: str) -> bool:
    return is_url_ref(value) and not is_local_url_ref(value)


def release_platform_url_error(value: str) -> str:
    return (
        f"refusing to run tests against a release platform URL: {value}\n"
        "For development, switch to a local platform path or local bundle file so tests exercise "
        "workspace changes. Pass --allow-release-platform-url only when intentionally verifying "
        "a published release."
    )


def ensure_release_platform_url_allowed(value: str, *, allow_release_platform_url: bool) -> None:
    if is_release_platform_url(value) and not allow_release_platform_url:
        raise SystemExit(release_platform_url_error(value))


def ensure_sources_do_not_use_release_platform_urls(
    examples: tuple[Example, ...],
    source_root: Path,
    *,
    allow_release_platform_url: bool,
) -> None:
    if allow_release_platform_url:
        return
    for example in examples:
        source = source_root / example.source
        if not source.is_file():
            continue
        match = PLATFORM_HEADER_CAPTURE_RE.search(source.read_text(encoding="utf-8"))
        if match is not None:
            ensure_release_platform_url_allowed(match.group(1), allow_release_platform_url=False)


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
    run([
        sys.executable,
        "-m",
        "unittest",
        "scripts/test_spec_driver.py",
        "scripts/test_benchmark_manifest.py",
        "scripts/test_known_failures.py",
    ])


def run_fuzz_suite() -> None:
    run([sys.executable, "scripts/fuzz.py", "check"])


def run_browser_suite() -> None:
    run(["zig", "build", "run-test-browser"])


def run_roc_checks(
    roc_bin: str,
    examples: tuple[Example, ...],
    *,
    source_root: Path = ROOT,
    allow_release_platform_url: bool = False,
) -> None:
    ensure_sources_do_not_use_release_platform_urls(
        examples,
        source_root,
        allow_release_platform_url=allow_release_platform_url,
    )
    for example in examples:
        run([roc_bin, "check", source_root / example.source])


def run_roc_tests(
    roc_bin: str,
    examples: tuple[Example, ...],
    *,
    source_root: Path = ROOT,
    allow_release_platform_url: bool = False,
) -> None:
    ensure_sources_do_not_use_release_platform_urls(
        examples,
        source_root,
        allow_release_platform_url=allow_release_platform_url,
    )
    for example in examples:
        run([roc_bin, "test", source_root / example.source])


def build_wasm_apps(roc_bin: str, examples: tuple[Example, ...], ledger: known_failures.Ledger) -> None:
    wasm_dir = TEST_OUT / "wasm"
    wasm_dir.mkdir(parents=True, exist_ok=True)
    bundle = bundle_platform(roc_bin)
    with BundleServer(bundle.resolve().parent) as server:
        platform_ref = f"http://127.0.0.1:{server.port}/{bundle.name}"
        print(f"\nTesting wasm apps with local platform bundle: {platform_ref}")
        source_root = TEST_OUT / "wasm-source"
        rewrite_examples_for_platform(platform_ref, source_root)
        ensure_sources_do_not_use_release_platform_urls(
            examples,
            source_root,
            allow_release_platform_url=False,
        )
        for example in examples:
            if not example.wasm:
                continue
            if platform.system() == "Linux" and example.slug in LINUX_WASM_SKIPS:
                print(f"\nSkipping wasm build for {example.slug} on Linux: {LINUX_WASM_SKIPS[example.slug]}.")
                continue
            output = wasm_dir / f"{example.slug}.wasm"
            try:
                run(
                    [
                        roc_bin,
                        "build",
                        "--target=wasm32",
                        "--opt=size",
                        "--no-cache",
                        f"--output={output}",
                        source_root / example.source,
                    ]
                )
            except subprocess.CalledProcessError as exc:
                ledger.record("wasm", example.slug, False, f"roc build exited with {exc.returncode}")
                continue
            mount_cmd = ["node", "scripts/browser/mount_wasm_example.mjs", output, example.slug]
            if example.expect_mount_error is not None:
                mount_cmd.extend(["--expect-error", example.expect_mount_error])
            if example.slug == "location-source":
                mount_cmd.append("--exercise-location-source")
            if example.slug == "location-navigation":
                mount_cmd.append("--exercise-location-navigation")
            if example.slug == "location-canonical-branch":
                mount_cmd.append("--exercise-location-canonical-branch")
            if example.slug == "storage-commands":
                mount_cmd.append("--exercise-storage-commands")
            try:
                run(mount_cmd)
            except subprocess.CalledProcessError as exc:
                ledger.record("wasm", example.slug, False, f"mount exited with {exc.returncode}")
                continue
            ledger.record("wasm", example.slug, True)


def should_run_hosted(mode: str) -> bool:
    if mode == "always":
        return True
    if mode == "never":
        return False
    return native_target_for_host() is not None


def native_exe_path(bin_dir: Path, exe_name: str) -> Path:
    suffix = ".exe" if platform.system() == "Windows" else ""
    return bin_dir / f"{exe_name}{suffix}"


def native_target_for_host() -> str | None:
    machine = platform.machine().lower()
    system = platform.system()
    if system == "Darwin":
        if machine in {"arm64", "aarch64"}:
            return "arm64mac"
        if machine in {"x86_64", "amd64"}:
            return "x64mac"
    if system == "Linux":
        if machine in {"arm64", "aarch64"}:
            return "arm64musl"
        if machine in {"x86_64", "amd64"}:
            return "x64musl"
    return None


def roc_native_target() -> str:
    target = native_target_for_host()
    if target is not None:
        return target
    raise SystemExit(
        f"unsupported platform for native specs: {platform.system()} {platform.machine()} "
        "(supported: macOS x64/arm64 and Linux x64/arm64 musl)"
    )


def native_cache_args(target: str) -> list[str]:
    # The Roc cache is keyed by content, not by compiler build, and a cache
    # written by one nightly has made another segfault at build time. Every
    # suite build therefore bypasses it, as the wasm builds already did; the
    # target is kept so a platform-specific exception has somewhere to live.
    _ = target
    return ["--no-cache"]


def should_skip_native_example(target: str, example: Example) -> str | None:
    if not target.endswith("musl"):
        return None
    return MUSL_NATIVE_SKIPS.get(example.slug)


def select_native_specs(
    spec_directory: Path,
    *,
    patterns: tuple[str, ...] = (),
    shard: tuple[int, int] | None = None,
) -> tuple[spec_driver.SpecCase, ...]:
    """Select one example's cases before paying its native build cost."""
    return spec_driver.select_specs(spec_driver.discover_specs(spec_directory), patterns=patterns, shard=shard)


def run_native_specs(
    roc_bin: str,
    examples: tuple[Example, ...],
    *,
    source_root: Path = ROOT,
    bin_dir: Path = TEST_OUT / "bin",
    allow_release_platform_url: bool = False,
    jobs: int | None = None,
    spec_filters: tuple[str, ...] = (),
    shard: tuple[int, int] | None = None,
    fail_fast: bool = False,
    spec_timeout: float = 30.0,
    ledger: known_failures.Ledger,
    fault_campaign: bool = False,
) -> None:
    ensure_sources_do_not_use_release_platform_urls(
        examples,
        source_root,
        allow_release_platform_url=allow_release_platform_url,
    )
    bin_dir.mkdir(parents=True, exist_ok=True)
    target = roc_native_target()
    matched_specs = 0
    for example in examples:
        if not example.native:
            continue
        if fault_campaign and example.slug not in FAULT_CAMPAIGN_EXAMPLES:
            continue
        if reason := should_skip_native_example(target, example):
            print(f"\nSkipping native spec for {example.slug} on {target}: {reason}.")
            continue
        if example.specs is None:
            raise SystemExit(f"{example.slug} is native but has no specs directory")
        source = source_root / example.source
        specs = source_root / example.specs
        selected = select_native_specs(specs, patterns=spec_filters, shard=shard)
        if not selected:
            continue
        matched_specs += len(selected)
        exe = native_exe_path(bin_dir, example.exe_name)
        try:
            run([roc_bin, "build", f"--target={target}", "--opt=dev", *native_cache_args(target), f"--output={exe}", source])
        except subprocess.CalledProcessError as exc:
            for case in selected:
                ledger.record("native", f"{example.slug}/{case.id}", False, f"roc build exited with {exc.returncode}")
            if fail_fast:
                break
            continue
        print(f"\n==> {exe} {specs}", flush=True)
        try:
            suite_runner = spec_driver.run_fault_suite if fault_campaign else spec_driver.run_suite
            benchmark_cases = load_benchmark_cases(example, source_root)
            serial_patterns = tuple(case.spec.name for case in benchmark_cases or () if case.serial_native_spec)
            timeout_overrides = {case.spec.name: case.native_spec_timeout_seconds for case in benchmark_cases or () if case.native_spec_timeout_seconds is not None}
            results = suite_runner(
                exe,
                specs,
                jobs=jobs,
                patterns=spec_filters,
                shard=shard,
                fail_fast=fail_fast,
                timeout_seconds=spec_timeout,
                **({} if fault_campaign else {"serial_patterns": serial_patterns, "timeout_overrides": timeout_overrides}),
            )
        except ValueError as exc:
            raise SystemExit(str(exc)) from exc
        spec_driver.print_summary(results)
        for result in results:
            detail = ""
            if result.failure:
                detail = f"{result.failure.get('phase', 'test')}/{result.failure.get('kind', 'failure')}: {result.failure.get('message', '')}"
            elif not result.passed:
                detail = result.status
            ledger.record("native", f"{example.slug}/{result.id}", result.passed, detail.strip())
        if fail_fast and not all(result.passed for result in results):
            break
    if matched_specs == 0:
        raise SystemExit("no native specs matched the requested filters and shard")


def run_benchmarks(roc_bin: str, examples: tuple[Example, ...], *, source_root: Path = ROOT) -> None:
    ensure_sources_do_not_use_release_platform_urls(
        examples,
        source_root,
        allow_release_platform_url=False,
    )
    bin_dir = TEST_OUT / "bench-bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    target = roc_native_target()
    for example in examples:
        if not example.bench:
            continue
        if reason := should_skip_native_example(target, example):
            print(f"\nSkipping benchmark for {example.slug} on {target}: {reason}.")
            continue
        if example.specs is None:
            raise SystemExit(f"{example.slug} is benchmarked but has no specs directory")
        source = source_root / example.source
        specs = source_root / example.specs
        exe = native_exe_path(bin_dir, f"{example.exe_name}-bench")
        run([roc_bin, "build", f"--target={target}", "--opt=speed", *native_cache_args(target), f"--output={exe}", source])
        manifest_cases = load_benchmark_cases(example, source_root)
        cases = manifest_cases or tuple(
            BenchmarkCase(case.id, example.specs / case.id, 0, 20, 1, False, None)
            for case in spec_driver.discover_specs(specs)
        )
        for case in cases:
            run(
                [
                    exe,
                    "--bench-app",
                    "--bench-name",
                    f"{example.exe_name}/{case.id}",
                    "--bench-warmup",
                    str(case.warmup_iterations),
                    "--bench-iterations",
                    str(case.native_iterations),
                    "--bench-samples",
                    str(case.native_samples),
                    source_root / case.spec,
                ]
            )


def benchmark_run(command: list[str | Path], *, cwd: Path = ROOT) -> None:
    """Run benchmark setup without contaminating the runner's CSV stdout."""
    printable = " ".join(str(part) for part in command)
    print(f"\n==> {printable}", file=sys.stderr, flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True, stdout=sys.stderr)


def prepare_wasm_benchmark_platform(destination: Path, host_object: Path, *, instrumented: bool) -> None:
    shutil.copytree(ROOT / "platform", destination, dirs_exist_ok=True)
    shutil.copy2(host_object, destination / "targets" / "wasm32" / "host.wasm")
    if not instrumented:
        return
    manifest = destination / "main.roc"
    source = manifest.read_text(encoding="utf-8")
    marker = '\t\t\t\t"roc_ui_command_buffer_len",\n'
    exports = (
        '\t\t\t\t"roc_ui_benchmark_metrics_checkpoint",\n'
        '\t\t\t\t"roc_ui_benchmark_metrics_len",\n'
        '\t\t\t\t"roc_ui_benchmark_metrics_ptr",\n'
        '\t\t\t\t"roc_ui_benchmark_metrics_reset",\n'
        '\t\t\t\t"roc_ui_benchmark_metrics_schema_version",\n'
    )
    if source.count(marker) != 1:
        raise SystemExit("benchmark platform could not locate the Wasm export list")
    manifest.write_text(source.replace(marker, exports + marker), encoding="utf-8")


def run_wasm_runtime_benchmarks(roc_bin: str, args: argparse.Namespace) -> None:
    output = TEST_OUT / "wasm-benchmark"
    output.mkdir(parents=True, exist_ok=True)
    benchmark_run(["zig", "build", "build-wasm-benchmark-host"])

    production_platform = output / "production-platform"
    diagnostic_platform = output / "diagnostic-platform"
    prepare_wasm_benchmark_platform(
        production_platform,
        ROOT / "zig-out" / "wasm-benchmark" / "production-host.o",
        instrumented=False,
    )
    prepare_wasm_benchmark_platform(
        diagnostic_platform,
        ROOT / "zig-out" / "wasm-benchmark" / "host.o",
        instrumented=True,
    )

    fixture = next(example for example in load_examples() if example.slug == "js-framework-benchmark")
    source_dir = output / "source"
    shutil.copytree(ROOT / fixture.source.parent, source_dir, dirs_exist_ok=True)
    production_source = source_dir / "production.roc"
    diagnostic_source = source_dir / "diagnostic.roc"
    original = (ROOT / fixture.source).read_text(encoding="utf-8")
    production_source.write_text(
        PLATFORM_HEADER_RE.sub(f'platform "{(production_platform / "main.roc").resolve()}"', original, count=1),
        encoding="utf-8",
    )
    diagnostic_source.write_text(
        PLATFORM_HEADER_RE.sub(f'platform "{(diagnostic_platform / "main.roc").resolve()}"', original, count=1),
        encoding="utf-8",
    )
    production_wasm = output / "js-framework-production.wasm"
    diagnostic_wasm = output / "js-framework-diagnostic.wasm"
    for source, wasm in ((production_source, production_wasm), (diagnostic_source, diagnostic_wasm)):
        benchmark_run([roc_bin, "build", "--target=wasm32", f"--opt={args.bench_app_opt}", "--no-cache", f"--output={wasm}", source])

    version = subprocess.run([roc_bin, "version"], check=True, capture_output=True, text=True).stdout.strip()
    fixture_digest = hashlib.sha256(original.encode("utf-8")).hexdigest()
    production_host = ROOT / "zig-out" / "wasm-benchmark" / "production-host.o"
    diagnostic_host = ROOT / "zig-out" / "wasm-benchmark" / "host.o"
    metadata = {
        "roc_compiler": version,
        "wasm_host_optimization": "ReleaseFast",
        "roc_app_optimization": args.bench_app_opt,
        "fixture": "js-framework-benchmark",
        "fixture_sha256": fixture_digest,
        "production_host_sha256": hashlib.sha256(production_host.read_bytes()).hexdigest(),
        "diagnostic_host_sha256": hashlib.sha256(diagnostic_host.read_bytes()).hexdigest(),
    }
    command: list[str | Path] = [
        "node", "scripts/browser/run_wasm_benchmarks.mjs",
        "--production", production_wasm,
        "--diagnostic", diagnostic_wasm,
        "--warmups", str(args.bench_warmups),
        "--iterations", str(args.bench_iterations),
        "--samples", str(args.bench_samples),
        "--metadata", json.dumps(metadata, separators=(",", ":")),
    ]
    for pattern in args.bench_case:
        command.extend(("--case", pattern))
    subprocess.run([str(part) for part in command], cwd=ROOT, check=True)


def rewrite_platform_headers(root: Path, platform_ref: str) -> None:
    replacement = f'platform "{platform_ref}"'
    for source in sorted(root.rglob("*.roc")):
        text = source.read_text(encoding="utf-8")
        updated, count = PLATFORM_HEADER_RE.subn(replacement, text, count=1)
        if count != 0:
            source.write_text(updated, encoding="utf-8")


def rewrite_examples_for_platform(platform_ref: str, dest_root: Path) -> None:
    if dest_root.exists():
        shutil.rmtree(dest_root)
    examples_dest = dest_root / "examples"
    shutil.copytree(ROOT / "examples", examples_dest, dirs_exist_ok=True)
    rewrite_platform_headers(examples_dest, platform_ref)


def run_local_native_specs(
    roc_bin: str,
    examples: tuple[Example, ...],
    *,
    jobs: int | None,
    spec_filters: tuple[str, ...],
    shard: tuple[int, int] | None,
    fail_fast: bool,
    spec_timeout: float,
    ledger: known_failures.Ledger,
    fault_campaign: bool = False,
) -> None:
    source_root = TEST_OUT / "native-source"
    rewrite_examples_for_platform(str((ROOT / "platform" / "main.roc").resolve()), source_root)
    run_native_specs(
        roc_bin,
        examples,
        source_root=source_root,
        jobs=jobs,
        spec_filters=spec_filters,
        shard=shard,
        fail_fast=fail_fast,
        spec_timeout=spec_timeout,
        ledger=ledger,
        fault_campaign=fault_campaign,
    )


def run_local_roc_checks(roc_bin: str, examples: tuple[Example, ...]) -> None:
    source_root = TEST_OUT / "roc-check-source"
    rewrite_examples_for_platform(str((ROOT / "platform" / "main.roc").resolve()), source_root)
    run_roc_checks(roc_bin, examples, source_root=source_root)


def run_local_roc_tests(roc_bin: str, examples: tuple[Example, ...]) -> None:
    source_root = TEST_OUT / "roc-test-source"
    rewrite_examples_for_platform(str((ROOT / "platform" / "main.roc").resolve()), source_root)
    run_roc_tests(roc_bin, examples, source_root=source_root)


def run_local_benchmarks(roc_bin: str, examples: tuple[Example, ...]) -> None:
    # Roc links the prebuilt platform host into each app. Rebuild it explicitly:
    # a Debug host enables quadratic render-cache assertions and makes large-list
    # timings measure validation machinery rather than production behavior.
    run(["zig", "build", "build-test-hosts", "-Doptimize=ReleaseFast"])
    source_root = TEST_OUT / "bench-source"
    rewrite_examples_for_platform(str((ROOT / "platform" / "main.roc").resolve()), source_root)
    run_benchmarks(roc_bin, examples, source_root=source_root)


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


def run_bundle_specs(
    roc_bin: str,
    examples: tuple[Example, ...],
    bundle_url: str,
    *,
    allow_release_platform_url: bool,
    jobs: int | None,
    spec_filters: tuple[str, ...],
    shard: tuple[int, int] | None,
    fail_fast: bool,
    spec_timeout: float,
    ledger: known_failures.Ledger,
) -> None:
    ensure_release_platform_url_allowed(bundle_url, allow_release_platform_url=allow_release_platform_url)
    print(f"\nTesting bundled platform: {bundle_url}")
    source_root = TEST_OUT / "bundle-source"
    rewrite_examples_for_platform(bundle_url, source_root)
    run_native_specs(
        roc_bin,
        examples,
        source_root=source_root,
        bin_dir=TEST_OUT / "bundle-bin",
        allow_release_platform_url=allow_release_platform_url,
        jobs=jobs,
        spec_filters=spec_filters,
        shard=shard,
        fail_fast=fail_fast,
        spec_timeout=spec_timeout,
        ledger=ledger,
    )


def run_bundle_file_suite(
    roc_bin: str,
    examples: tuple[Example, ...],
    bundle: Path,
    **spec_options: object,
) -> None:
    with BundleServer(bundle.resolve().parent) as server:
        bundle_url = f"http://127.0.0.1:{server.port}/{bundle.name}"
        run_bundle_specs(roc_bin, examples, bundle_url, allow_release_platform_url=False, **spec_options)


def run_bundle_suite(
    roc_bin: str,
    examples: tuple[Example, ...],
    bundle_ref: str | None,
    *,
    allow_release_platform_url: bool,
    jobs: int | None,
    spec_filters: tuple[str, ...],
    shard: tuple[int, int] | None,
    fail_fast: bool,
    spec_timeout: float,
    ledger: known_failures.Ledger,
) -> None:
    spec_options = {
        "jobs": jobs,
        "spec_filters": spec_filters,
        "shard": shard,
        "fail_fast": fail_fast,
        "spec_timeout": spec_timeout,
        "ledger": ledger,
    }
    if bundle_ref is None:
        run_bundle_file_suite(roc_bin, examples, bundle_platform(roc_bin), **spec_options)
        return

    if is_url_ref(bundle_ref):
        run_bundle_specs(
            roc_bin,
            examples,
            bundle_ref,
            allow_release_platform_url=allow_release_platform_url,
            **spec_options,
        )
        return

    bundle = Path(bundle_ref)
    if not bundle.is_absolute():
        bundle = ROOT / bundle
    if not bundle.is_file():
        raise SystemExit(f"bundle file not found: {bundle_ref}")
    run_bundle_file_suite(roc_bin, examples, bundle, **spec_options)


def validate_args_before_build(args: argparse.Namespace, suites: set[str]) -> None:
    if args.spec_timeout <= 0:
        raise SystemExit("--spec-timeout must be greater than zero")
    if args.bench_warmups < 0 or args.bench_iterations <= 0 or args.bench_samples <= 0:
        raise SystemExit("Wasm benchmark warmups must be non-negative and iterations/samples must be positive")
    if "bundle" not in suites:
        return
    if not should_run_hosted(args.bundle):
        return
    if args.bundle_ref is not None:
        ensure_release_platform_url_allowed(
            args.bundle_ref,
            allow_release_platform_url=args.allow_release_platform_url,
        )


def main() -> int:
    args = parse_args()
    examples = load_examples()
    suites = set(args.suites)
    if "all" in suites:
        suites = {"zig", "fuzz", "browser", "roc-check", "roc-test", "wasm", "native", "fault", "bundle", "bench"}

    validate_args_before_build(args, suites)
    roc_bin = command_path(args.roc_bin)
    ensure_clean_output(args.keep_output)

    build_hosts()

    if "zig" in suites:
        run_zig_suite()
    if "fuzz" in suites:
        run_fuzz_suite()
    if "browser" in suites:
        run_browser_suite()
    if "roc-check" in suites:
        run_local_roc_checks(roc_bin, examples)
    if "roc-test" in suites:
        run_local_roc_tests(roc_bin, examples)
    known_failures_path = Path(args.known_failures)
    try:
        ledger = known_failures.Ledger(known=known_failures.load(known_failures_path))
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    if "wasm" in suites:
        build_wasm_apps(roc_bin, examples, ledger)

    if "wasm-bench" in suites:
        run_wasm_runtime_benchmarks(roc_bin, args)

    if "native" in suites:
        if should_run_hosted(args.native):
            run_local_native_specs(
                roc_bin,
                examples,
                jobs=args.jobs,
                spec_filters=tuple(args.spec_filter),
                shard=args.shard,
                fail_fast=args.fail_fast,
                spec_timeout=args.spec_timeout,
                ledger=ledger,
            )
        else:
            print("\nSkipping native specs: platform manifest exposes macOS and Linux musl native targets only.")

    if "fault" in suites:
        if should_run_hosted(args.native):
            run_local_native_specs(
                roc_bin,
                examples,
                jobs=args.jobs,
                spec_filters=tuple(args.spec_filter),
                shard=args.shard,
                fail_fast=args.fail_fast,
                spec_timeout=args.spec_timeout,
                ledger=ledger,
                fault_campaign=True,
            )
        else:
            print("\nSkipping host fault campaign: native execution is disabled.")

    if "bundle" in suites:
        if should_run_hosted(args.bundle):
            run_bundle_suite(
                roc_bin,
                examples,
                args.bundle_ref,
                allow_release_platform_url=args.allow_release_platform_url,
                jobs=args.jobs,
                spec_filters=tuple(args.spec_filter),
                shard=args.shard,
                fail_fast=args.fail_fast,
                spec_timeout=args.spec_timeout,
                ledger=ledger,
            )
        else:
            print("\nSkipping bundle executable tests: platform manifest exposes macOS and Linux musl native targets only.")

    if "bench" in suites:
        if should_run_hosted(args.native):
            run_local_benchmarks(roc_bin, examples)
        else:
            print("\nSkipping benchmarks: platform manifest exposes macOS and Linux musl native targets only.")

    if not args.keep_output and TEST_OUT.exists():
        shutil.rmtree(TEST_OUT)
    if not ledger.outcomes:
        return 0
    status = known_failures.report(ledger, known_failures_path)
    if args.update_known_failures and ledger.fixed:
        removed = known_failures.remove_fixed(known_failures_path, ledger)
        print(f"removed {removed} fixed entr{'y' if removed == 1 else 'ies'} from {known_failures_path}")
        status = 1 if ledger.regressions else 0
    return status


if __name__ == "__main__":
    raise SystemExit(main())
