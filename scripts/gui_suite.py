"""Build and test maintained GUI applications through the shared native runner."""

from pathlib import Path
import os
import platform
import re
import subprocess
import sys
import tomllib

import spec_driver
import toolchain


ROOT = Path(__file__).resolve().parent.parent


def supported_host() -> bool:
    return platform.system() == "Linux" and platform.machine() == "x86_64"


def examples(root: Path = ROOT) -> tuple[Path, ...]:
    directory = root / "examples-gui"
    manifest = tomllib.loads((directory / "examples.toml").read_text())
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported GUI example manifest schema")
    slugs = [entry["slug"] for entry in manifest.get("examples", [])]
    if not slugs or len(slugs) != len(set(slugs)):
        raise ValueError("GUI example manifest must contain distinct apps")
    for slug in slugs:
        if not isinstance(slug, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
            raise ValueError(f"invalid GUI example slug: {slug!r}")
    discovered = {path.parent.name for path in directory.glob("*/main.roc")}
    if set(slugs) != discovered:
        raise ValueError(f"GUI example manifest differs from app directories: {set(slugs) ^ discovered}")
    for slug in slugs:
        spec_driver.discover_specs(directory / slug / "specs")
    return tuple(directory / slug for slug in slugs)


def fixtures(root: Path = ROOT) -> tuple[Path, ...]:
    apps = tuple(sorted(path.parent for path in (root / "test/gui").glob("*/main.roc")))
    for app in apps:
        spec_driver.discover_specs(app / "specs")
    return apps


def run(roc: str, args, output: Path) -> None:
    if not supported_host():
        raise SystemExit("GUI tests require Linux x86_64 with glibc; no display is needed.")
    apps = examples() + fixtures()
    toolchain.verify_compiler(roc, toolchain.read_pin(ROOT / "platform-gui/main.roc"))
    subprocess.run([sys.executable, ROOT / "scripts/prepare_platforms.py"], check=True)
    subprocess.run(
        [sys.executable, ROOT / "scripts/build_gui.py", "--debug", "--jobs", str(args.gui_build_jobs)],
        check=True,
    )
    environment = os.environ.copy()
    library_path = str(ROOT / "platform-gui/targets/x64glibc")
    if environment.get("LIBRARY_PATH"):
        library_path += os.pathsep + environment["LIBRARY_PATH"]
    environment["LIBRARY_PATH"] = library_path
    subprocess.run(
        ["cargo", "test", "--locked", "-p", "signals-gpui-host", "--lib", "-j",
         str(args.gui_build_jobs), "--", "--test-threads=1"],
        cwd=ROOT, env=environment, check=True,
    )
    output.mkdir(parents=True, exist_ok=True)
    failures = []
    matched = 0
    for app in apps:
        cases = spec_driver.select_specs(
            spec_driver.discover_specs(app / "specs"),
            patterns=tuple(args.spec_filter), shard=args.shard,
        )
        if not cases:
            continue
        matched += len(cases)
        source = app / "main.roc"
        name = app.name if app.parent.name == "examples-gui" else "fixture-" + app.name
        executable = output / name
        try:
            for command in (
                [roc, "check", source],
                [roc, "test", source],
                [roc, "build", "--target=x64glibc", "--opt=dev", "--no-cache", f"--output={executable}", source],
            ):
                print("\n==> " + " ".join(map(str, command)), flush=True)
                subprocess.run(command, cwd=output, check=True)
        except subprocess.CalledProcessError:
            failures.append(app.name)
            if args.fail_fast:
                break
            continue
        results = spec_driver.run_suite(
            executable, app / "specs", jobs=args.jobs,
            patterns=tuple(args.spec_filter), shard=args.shard,
            fail_fast=args.fail_fast, timeout_seconds=args.spec_timeout,
        )
        spec_driver.print_summary(results)
        if any(not result.passed for result in results):
            failures.append(app.name)
            if args.fail_fast:
                break
    if not matched:
        raise SystemExit("no GUI specs matched the requested filters and shard")
    if failures:
        raise SystemExit("GUI suite failed: " + ", ".join(failures))
