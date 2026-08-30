#!/usr/bin/env python3
"""Fuzzing driver for Roc Signals.

Wraps `zig build build-fuzz` and AFL++ so that the target list, corpus layout,
seeding, environment variables, and crash triage live here rather than in
whoever last read the contributing docs.

Run `python3 scripts/fuzz.py --help` for the available commands.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORK_DIR = ROOT / ".fuzz-out"
BIN_DIR = ROOT / "zig-out" / "bin"

# AFL++ refuses to start on many developer machines without these. Neither
# weakens the fuzzing itself: the first only skips a CPU-governor check, and the
# second only silences the warning about the system core-dump handler, which
# matters because a handler that writes crash reports can make AFL++ miss the
# crash it just caused.
AFL_ENV = {
    "AFL_SKIP_CPUFREQ": "1",
    "AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES": "1",
}


@dataclass(frozen=True)
class Target:
    name: str
    summary: str
    # Generator targets decode any byte string into a valid program, so a single
    # byte is a sufficient seed. The byte-oriented target benefits from real
    # examples, which it produces itself from the canonical descriptors.
    seed: bytes = b"\0"

    @property
    def fuzz_exe(self) -> Path:
        return BIN_DIR / f"fuzz-{self.name}"

    @property
    def repro_exe(self) -> Path:
        return BIN_DIR / f"repro-{self.name}"

    @property
    def work_dir(self) -> Path:
        return WORK_DIR / self.name

    @property
    def corpus_dir(self) -> Path:
        return self.work_dir / "corpus"

    @property
    def out_dir(self) -> Path:
        return self.work_dir / "out"


TARGETS = (
    Target("propagation", "dependency-ordered, glitch-free propagation and equality cutoffs"),
    Target("keyed-scopes", "keyed-row identity, scope retirement, reuse barriers, disposal"),
    Target("structural", "collect/prepare/commit atomicity under allocation failure"),
    Target("ownership", "retained-value and callable ownership across erased calls"),
    Target("boundary", "boundary schema and event extraction plan parsing"),
)

TARGETS_BY_NAME = {target.name: target for target in TARGETS}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def resolve_targets(names: list[str]) -> list[Target]:
    """Expands target names, treating an empty list or `all` as every target."""
    if not names or names == ["all"]:
        return list(TARGETS)

    resolved = []
    for name in names:
        target = TARGETS_BY_NAME.get(name)
        if target is None:
            known = ", ".join(sorted(TARGETS_BY_NAME))
            die(f"unknown target '{name}'; known targets are: {known}")
        resolved.append(target)
    return resolved


def parse_duration(text: str) -> int:
    """Parses a duration such as `90`, `30s`, `10m`, or `2h` into seconds."""
    match = re.fullmatch(r"(\d+)([smh]?)", text.strip())
    if match is None:
        die(f"could not parse duration '{text}'; use forms like 30s, 10m, 2h")
    value = int(match.group(1))
    return value * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def have_afl() -> bool:
    return shutil.which("afl-fuzz") is not None and shutil.which("afl-cc") is not None


def build(with_afl: bool) -> None:
    """Builds the repro executables, and the AFL++ executables when possible."""
    command = ["zig", "build", "build-fuzz"]
    if with_afl:
        command.append("-Dfuzz")
    print(f"$ {' '.join(command)}")
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        die("build failed")


def ensure_built(targets: list[Target], need_afl: bool, skip_build: bool) -> None:
    if not skip_build:
        build(with_afl=need_afl)

    for target in targets:
        exe = target.fuzz_exe if need_afl else target.repro_exe
        if not exe.exists():
            hint = " (is AFL++ installed?)" if need_afl else ""
            die(f"missing {exe.relative_to(ROOT)}{hint}")


def seed_corpus(target: Target) -> None:
    """Creates the corpus directory and plants a seed if it is empty.

    AFL++ refuses to start against an empty input directory. The corpus is kept
    between runs on purpose: inputs AFL++ found interesting last time are the
    cheapest way to reach deep engine states quickly on the next run.
    """
    target.corpus_dir.mkdir(parents=True, exist_ok=True)
    if any(target.corpus_dir.iterdir()):
        return
    (target.corpus_dir / "seed").write_bytes(target.seed)


def read_stats(target: Target, instance: str = "default") -> dict[str, str]:
    stats_path = target.out_dir / instance / "fuzzer_stats"
    if not stats_path.exists():
        return {}

    stats = {}
    for line in stats_path.read_text().splitlines():
        key, _, value = line.partition(":")
        stats[key.strip()] = value.strip()
    return stats


def crash_files(target: Target) -> list[Path]:
    """Lists saved crash inputs across every fuzzer instance for a target."""
    if not target.out_dir.exists():
        return []
    return sorted(
        path
        for path in target.out_dir.glob("*/crashes/*")
        if path.is_file() and path.name != "README.txt"
    )


def run_one(target: Target, seconds: int | None, jobs: int, resume: bool) -> None:
    """Fuzzes a single target, optionally across several cores."""
    if not resume and target.out_dir.exists():
        shutil.rmtree(target.out_dir)
    seed_corpus(target)
    target.out_dir.mkdir(parents=True, exist_ok=True)

    env = {**os.environ, **AFL_ENV}

    base = [
        "afl-fuzz",
        "-i",
        "-" if resume else str(target.corpus_dir),
        "-o",
        str(target.out_dir),
    ]
    if seconds is not None:
        # `-V` is a wall-clock limit that AFL++ enforces itself, so it still
        # writes out its stats and corpus on the way out. This is deliberately
        # not `AFL_EXIT_ON_TIME`, which measures time since the last new find
        # and so runs for an unbounded total on a target that keeps finding.
        base += ["-V", str(seconds)]

    processes = []
    for index in range(jobs):
        # One primary instance drives deterministic mutations; the rest are
        # secondaries doing havoc, which is how AFL++ expects to use many cores.
        role = ["-M", "primary"] if index == 0 else ["-S", f"secondary{index}"]
        command = [*base, *role, "--", str(target.fuzz_exe)]

        log_path = target.work_dir / f"afl-{index}.log"
        log = open(log_path, "w")
        # Only the first instance draws the AFL++ status screen; the others would
        # fight it for the terminal, so their output goes to a log file.
        stdout = None if (index == 0 and jobs == 1) else log
        processes.append((subprocess.Popen(command, cwd=ROOT, env=env, stdout=stdout, stderr=log), log))

    if jobs > 1 or seconds is not None:
        print(f"fuzzing {target.name} with {jobs} instance(s); logs in {target.work_dir.relative_to(ROOT)}")

    try:
        for process, log in processes:
            process.wait()
            log.close()
    except KeyboardInterrupt:
        for process, log in processes:
            process.send_signal(signal.SIGINT)
        for process, log in processes:
            process.wait()
            log.close()

    # An instance that could not start (no shared memory, a rejected binary)
    # exits non-zero before fuzzing anything; reporting "no crashes" for it
    # would turn a broken setup into a clean bill of health.
    failed = [index for index, (process, _) in enumerate(processes) if process.returncode != 0]
    if failed:
        die(f"afl-fuzz instance(s) {failed} exited with an error; see {target.work_dir.relative_to(ROOT)}/afl-*.log")


def command_run(args: argparse.Namespace) -> int:
    targets = resolve_targets(args.targets)
    if not have_afl():
        die("afl-fuzz and afl-cc are required; install AFL++ (apt install afl++, brew install afl++)")

    ensure_built(targets, need_afl=True, skip_build=args.no_build)
    seconds = parse_duration(args.time) if args.time else None

    if len(targets) > 1 and seconds is None:
        die("fuzzing more than one target requires --time, since each runs to completion in turn")

    for target in targets:
        print(f"\n=== {target.name}: {target.summary} ===", flush=True)
        started = time.monotonic()
        run_one(target, seconds, args.jobs, args.resume)
        elapsed = time.monotonic() - started
        report_target(target, elapsed)

    return 1 if any(crash_files(target) for target in targets) else 0


def report_target(target: Target, elapsed: float | None = None) -> None:
    stats = read_stats(target, "primary") or read_stats(target)
    crashes = crash_files(target)

    if elapsed is not None:
        print(f"ran for {elapsed:.0f}s")
    if stats:
        print(
            "  execs/sec: {execs}  edges: {edges}  stability: {stability}".format(
                execs=stats.get("execs_per_sec", "?"),
                edges=stats.get("edges_found", "?"),
                stability=stats.get("stability", "?"),
            )
        )
        stability = stats.get("stability", "").rstrip("%")
        if stability and float(stability) < 90.0:
            print(
                "  warning: stability below 90% means the target is not deterministic\n"
                "           for a fixed input; fix that before trusting any crash."
            )

    if not crashes:
        print("  no crashes")
        return

    print(f"  {len(crashes)} crash input(s):")
    for path in crashes:
        print(f"    {path.relative_to(ROOT)}")
    print(f"  replay with: python3 scripts/fuzz.py repro {target.name} <file>")


def command_repro(args: argparse.Namespace) -> int:
    target = resolve_targets([args.target])[0]
    ensure_built([target], need_afl=False, skip_build=args.no_build)

    command = [str(target.repro_exe)]
    if args.verbose:
        command.append("--verbose")
    command.append(str(Path(args.input).resolve()))

    print(f"$ {' '.join(command)}")
    return subprocess.run(command, cwd=ROOT).returncode


def command_minimize(args: argparse.Namespace) -> int:
    target = resolve_targets([args.target])[0]
    if shutil.which("afl-tmin") is None:
        die("afl-tmin is required; install AFL++")
    ensure_built([target], need_afl=True, skip_build=args.no_build)

    output = Path(args.output).resolve() if args.output else target.work_dir / "minimized"
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "afl-tmin",
        "-i",
        str(Path(args.input).resolve()),
        "-o",
        str(output),
        "--",
        str(target.fuzz_exe),
    ]
    print(f"$ {' '.join(command)}")
    result = subprocess.run(command, cwd=ROOT, env={**os.environ, **AFL_ENV})
    if result.returncode == 0:
        print(f"\nminimized input written to {output}")
        print(f"replay with: python3 scripts/fuzz.py repro {target.name} {output} --verbose")
    return result.returncode


def command_status(args: argparse.Namespace) -> int:
    targets = resolve_targets(args.targets)
    found_crashes = False
    for target in targets:
        print(f"\n=== {target.name} ===")
        if not target.out_dir.exists():
            print("  never run")
            continue
        report_target(target)
        found_crashes = found_crashes or bool(crash_files(target))
    return 1 if found_crashes else 0


def command_list(_args: argparse.Namespace) -> int:
    width = max(len(target.name) for target in TARGETS)
    for target in TARGETS:
        print(f"{target.name:<{width}}  {target.summary}")
    return 0


def command_build(args: argparse.Namespace) -> int:
    with_afl = have_afl() and not args.no_afl
    if not with_afl and not args.no_afl:
        print("AFL++ not found; building repro executables only")
    build(with_afl=with_afl)
    return 0


def command_clean(args: argparse.Namespace) -> int:
    targets = resolve_targets(args.targets)
    for target in targets:
        if target.work_dir.exists():
            shutil.rmtree(target.work_dir)
            print(f"removed {target.work_dir.relative_to(ROOT)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scripts/fuzz.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  python3 scripts/fuzz.py list\n"
            "  python3 scripts/fuzz.py run propagation --time 10m\n"
            "  python3 scripts/fuzz.py run all --time 5m -j 4\n"
            "  python3 scripts/fuzz.py status\n"
            "  python3 scripts/fuzz.py repro propagation <crash-file> --verbose\n"
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_no_build(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--no-build", action="store_true", help="use the existing executables instead of rebuilding")

    list_parser = subparsers.add_parser("list", help="list the fuzz targets")
    list_parser.set_defaults(func=command_list)

    build_parser_ = subparsers.add_parser("build", help="build the fuzz and repro executables")
    build_parser_.add_argument("--no-afl", action="store_true", help="build only the repro executables")
    build_parser_.set_defaults(func=command_build)

    run_parser = subparsers.add_parser("run", help="fuzz one or more targets")
    run_parser.add_argument("targets", nargs="*", help="target names, or 'all' (the default)")
    run_parser.add_argument("--time", help="stop each target after this long, e.g. 30s, 10m, 2h")
    run_parser.add_argument("-j", "--jobs", type=int, default=1, help="parallel AFL++ instances per target")
    run_parser.add_argument("--resume", action="store_true", help="continue the previous session instead of starting fresh")
    add_no_build(run_parser)
    run_parser.set_defaults(func=command_run)

    status_parser = subparsers.add_parser("status", help="report stats and crashes from previous runs")
    status_parser.add_argument("targets", nargs="*", help="target names, or 'all' (the default)")
    status_parser.set_defaults(func=command_status)

    repro_parser = subparsers.add_parser("repro", help="replay one input through a target")
    repro_parser.add_argument("target")
    repro_parser.add_argument("input", help="path to a crash or corpus input")
    repro_parser.add_argument("-v", "--verbose", action="store_true", help="print the generated program")
    add_no_build(repro_parser)
    repro_parser.set_defaults(func=command_repro)

    minimize_parser = subparsers.add_parser("minimize", help="shrink a crash input with afl-tmin")
    minimize_parser.add_argument("target")
    minimize_parser.add_argument("input")
    minimize_parser.add_argument("-o", "--output", help="where to write the minimized input")
    add_no_build(minimize_parser)
    minimize_parser.set_defaults(func=command_minimize)

    clean_parser = subparsers.add_parser("clean", help="remove corpora and fuzzer output")
    clean_parser.add_argument("targets", nargs="*", help="target names, or 'all' (the default)")
    clean_parser.set_defaults(func=command_clean)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
