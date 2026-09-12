#!/usr/bin/env python3
"""Fuzzing driver for Roc Signals.

Wraps `zig build build-fuzz` and AFL++ so that the target list, corpus layout,
seeding, environment variables, and crash triage live here rather than in
whoever last read the contributing docs.

Run `python3 scripts/fuzz.py --help` for the available commands.
"""

from __future__ import annotations

import argparse
import hashlib
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

# Inputs committed to the repository, replayed by `check`. A fuzzer that finds a
# crash is only worth the run it found it in unless the input outlives the run,
# so a triaged crash is minimized and landed here, where CI replays it forever.
# `.fuzz-out` corpora are scratch by comparison: they are large, machine-specific,
# and deleted by `clean`.
REGRESSION_DIR = ROOT / "test" / "fuzzing" / "corpus"
KNOWN_FAILURES_PATH = REGRESSION_DIR / "known-failures.txt"

# AFL++ refuses to start on many developer machines without these. Neither
# weakens the fuzzing itself: the first only skips a CPU-governor check, and the
# second only silences the warning about the system core-dump handler, which
# matters because a handler that writes crash reports can make AFL++ miss the
# crash it just caused.
AFL_ENV = {
    "AFL_SKIP_CPUFREQ": "1",
    "AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES": "1",
}

# Files `distill` writes into the committed corpus, named by content hash so a
# re-distillation of the same queue rewrites the same files and a review diff
# shows only what actually changed. Hand-named inputs (`add`) are never touched.
DISTILLED_PREFIX = "distilled-"
# The per-target cap on what `distill` will commit. The corpus is replayed on
# every pull request and read by people, so it has to stay small: 400 inputs is
# a few seconds of replay per target, and 1 MB keeps the repository's largest
# directory of opaque bytes readable in a diff. When the edge cover is larger
# than the cap, inputs are kept in order of how many uncovered edges each adds,
# so what is dropped is what contributed least.
DISTILL_MAX_INPUTS = 400
DISTILL_MAX_BYTES = 1_000_000



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

    @property
    def regression_dir(self) -> Path:
        return REGRESSION_DIR / self.name

    def regression_key(self, path: Path) -> str:
        return f"{self.name}/{path.name}"

    def regression_inputs(self) -> list[Path]:
        if not self.regression_dir.exists():
            return []
        return sorted(path for path in self.regression_dir.iterdir() if path.is_file() and path.name != "README.md")

    def distilled_inputs(self) -> list[Path]:
        return [path for path in self.regression_inputs() if path.name.startswith(DISTILLED_PREFIX)]

    def queue_inputs(self) -> list[Path]:
        """Lists the live queue of every fuzzer instance, the raw material `distill` refines."""
        if not self.out_dir.exists():
            return []
        return sorted(path for path in self.out_dir.glob("*/queue/*") if path.is_file() and not path.name.startswith("."))


TARGETS = (
    Target("propagation", "dependency-ordered, glitch-free propagation and equality cutoffs"),
    Target("keyed-scopes", "keyed-row identity, scope retirement, reuse barriers, disposal"),
    Target("rows-transitions", "canonical stable-slot Rows transitions, lineage, abort, and retry"),
    Target("structural", "collect/prepare/commit atomicity under allocation failure"),
    Target("ownership", "retained-value and callable ownership across erased calls"),
    Target("boundary", "boundary schema and event extraction plan parsing"),
)

TARGETS_BY_NAME = {target.name: target for target in TARGETS}



def read_known_failures() -> set[str]:
    """Reads the inputs currently expected to fail, as `<target>/<input>` keys.

    The ratchet is the one in `scripts/known_failures.py`, applied to the fuzz
    corpus: a listed input that now passes fails the run so the line gets
    deleted, and an unlisted failure is a regression. Entries are only ever
    added by hand, next to a comment saying which bug is being accepted.
    """
    if not KNOWN_FAILURES_PATH.exists():
        return set()

    known = set()
    for line in KNOWN_FAILURES_PATH.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            known.add(entry)
    return known


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
    """Adds committed regressions without discarding local campaign seeds.

    AFL++ refuses to start against an empty input directory. The corpus is kept
    between runs on purpose: inputs AFL++ found interesting last time are the
    cheapest way to reach deep engine states quickly on the next run.
    """
    target.corpus_dir.mkdir(parents=True, exist_ok=True)
    for regression in target.regression_inputs():
        shutil.copyfile(regression, target.corpus_dir / f"regression-{regression.name}")
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


def afl_env(target: Target) -> dict[str, str]:
    """The AFL++ environment for tools that run a target outside `afl-fuzz`.

    The targets carry far more edges than AFL++'s default 64 KiB map. `afl-fuzz`
    learns the real size from the forkserver handshake, but `afl-showmap`
    (behind `afl-cmin`) and `afl-tmin` refuse to guess, and without the size
    they abort or record a truncated map - which showed up as `afl-cmin`
    treating every input as a crash. `afl-fuzz` prints the size it learned at
    startup, and every `run` keeps that log, so it is read back from there.
    """
    env = {**os.environ, **AFL_ENV}
    log_path = target.work_dir / "afl-0.log"
    if log_path.exists():
        match = re.search(r"Target map size: (\d+)", log_path.read_text(errors="replace"))
        if match is not None:
            env["AFL_MAP_SIZE"] = match.group(1)
    if "AFL_MAP_SIZE" not in env:
        die(f"could not learn the map size of {target.name}; run it once with `fuzz.py run` first, or set AFL_MAP_SIZE")
    return env


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


def content_name(data: bytes) -> str:
    return DISTILLED_PREFIX + hashlib.sha256(data).hexdigest()[:12]


def trace_inputs(target: Target, candidates: Path, traces: Path, jobs: int) -> None:
    """Records the coverage tuples of every candidate with `afl-showmap`.

    `afl-cmin` is not used, although this is its first half: it asks the binary
    for its map size through `AFL_DUMP_MAP_SIZE`, which the pc-guard runtime
    answers with the 64 KiB default, and it pins that answer over any
    `AFL_MAP_SIZE` in the environment, so on these targets every trace is
    truncated and every input is reported as crashing. `afl-showmap -i` with the
    real size is what `afl-cmin` runs underneath, minus that override, and
    sharding the candidates across `jobs` invocations is its `-T`.
    """
    shards = [candidates / f"shard-{index}" for index in range(jobs)]
    for shard in shards:
        shard.mkdir()
    for index, path in enumerate(sorted(p for p in candidates.iterdir() if p.is_file())):
        path.rename(shards[index % jobs] / path.name)

    env = afl_env(target)
    processes = []
    for index, shard in enumerate(shards):
        command = ["afl-showmap", "-q", "-e", "-i", str(shard), "-o", str(traces), "--", str(target.fuzz_exe)]
        if index == 0:
            print(f"$ {' '.join(command)}  (x{jobs})")
        log = open(target.work_dir / f"showmap-{index}.log", "w")
        # afl-showmap drops temporary files in its working directory.
        processes.append((subprocess.Popen(command, cwd=target.work_dir, env=env, stdout=log, stderr=subprocess.STDOUT), log))
    failed = False
    for process, log in processes:
        failed |= process.wait() != 0
        log.close()
    if failed:
        die(f"afl-showmap failed; see {target.work_dir.relative_to(ROOT)}/showmap-*.log")


def cover_edges(candidates: Path, traces: Path, max_inputs: int, max_bytes: int) -> list[Path]:
    """Keeps the inputs that reach every edge, then ranks them by what they add.

    The first pass is `afl-cmin`'s set cover: edges are visited from rarest to
    commonest and each is claimed by its smallest candidate, ties broken by
    name, so the result depends only on the candidates and never on directory
    order. Survivors are then taken greedily by how many still-uncovered edges
    each adds until `max_inputs` or `max_bytes` is reached, so when the cover
    is larger than the cap what is dropped is what contributed least.
    """
    inputs = sorted((path for path in candidates.rglob("*") if path.is_file()), key=lambda p: (p.stat().st_size, p.name))
    edges_of: list[set[str]] = []
    by_edge: dict[str, list[int]] = {}
    for index, path in enumerate(inputs):
        trace = traces / path.name
        if not trace.exists():
            # afl-showmap skips an empty file rather than running it, so the
            # empty input reaches nothing here; `check` still replays it.
            if path.stat().st_size != 0:
                die(f"no trace for {path.name}: it crashed or timed out under afl-showmap")
            edges_of.append(set())
            continue
        edges = set(trace.read_text().split())
        edges_of.append(edges)
        for edge in edges:
            by_edge.setdefault(edge, []).append(index)
    cover: set[int] = set()
    for edge in sorted(by_edge, key=lambda e: (len(by_edge[e]), e)):
        if not any(index in cover for index in by_edge[edge]):
            cover.add(min(by_edge[edge]))
    print(f"{len(by_edge)} edges across {len(inputs)} candidate(s); {len(cover)} input(s) cover them")

    kept: list[int] = []
    covered: set[str] = set()
    remaining = set(cover)
    budget = max_bytes
    while remaining and len(kept) < max_inputs:
        best = max(remaining, key=lambda i: (len(edges_of[i] - covered), -inputs[i].stat().st_size, inputs[i].name))
        remaining.remove(best)
        size = inputs[best].stat().st_size
        if size > budget:
            continue
        kept.append(best)
        covered |= edges_of[best]
        budget -= size
    if remaining:
        lost = len(set().union(*(edges_of[i] for i in remaining)) - covered)
        print(f"cap reached: {len(remaining)} survivor(s) dropped, giving up {lost} edge(s) of {len(by_edge)}")
    return [inputs[index] for index in kept]


def afl_tmin(target: Target, source: Path, destination: Path, seconds: int) -> bool:
    """Shrinks one input in place of `destination`, giving up after `seconds`."""
    command = ["afl-tmin", "-i", str(source), "-o", str(destination), "--", str(target.fuzz_exe)]
    try:
        result = subprocess.run(command, cwd=ROOT, env=afl_env(target), capture_output=True, timeout=seconds)
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0 and destination.is_file()


def command_distill(args: argparse.Namespace) -> int:
    """Refines the live AFL++ queues into a small committed corpus.

    A campaign restarts from the committed corpus, so what is not carried
    forward is searched for again next time. The queue is traced with
    `afl-showmap` and reduced to the smallest set of inputs that still reaches
    every coverage tuple it reached, which is what `afl-cmin` does; the
    survivors are replayed through the repro executable, since an input that
    fails would turn `check` red and belongs in `add` beside its fix instead;
    then they are written under content-hash names, replacing the previous
    distillate, within `DISTILL_MAX_INPUTS` and `DISTILL_MAX_BYTES`.
    """
    target = resolve_targets([args.target])[0]
    ensure_built([target], need_afl=True, skip_build=args.no_build)

    # The previous distillate competes on equal terms with the new queue, so
    # an old input survives only while nothing reaches its edges more cheaply.
    # Hand-named inputs are candidates too, so a queue entry that only repeats
    # one of them is not kept twice, but they are never renamed or removed.
    named = [path for path in target.regression_inputs() if not path.name.startswith(DISTILLED_PREFIX)]
    candidates = target.queue_inputs() + target.distilled_inputs() + named
    if not target.queue_inputs():
        die(f"no live queue for {target.name}; run a campaign first")

    staging = target.work_dir / "distill"
    if staging.exists():
        shutil.rmtree(staging)
    candidate_dir = staging / "candidates"
    trace_dir = staging / "traces"
    candidate_dir.mkdir(parents=True)
    seen: set[bytes] = set()
    for path in candidates:
        data = path.read_bytes()
        if data in seen:
            continue
        seen.add(data)
        (candidate_dir / content_name(data)).write_bytes(data)
    print(f"{len(seen)} distinct candidate(s) from {len(target.queue_inputs())} queue input(s)")

    trace_inputs(target, candidate_dir, trace_dir, args.jobs)
    named_contents = {path.read_bytes() for path in named}
    # Hand-named inputs are always committed, so they are counted against the
    # byte budget but not against the input cap, which bounds the distillate.
    named_bytes = sum(path.stat().st_size for path in named)
    survivors = [
        path
        for path in cover_edges(candidate_dir, trace_dir, DISTILL_MAX_INPUTS + len(named), DISTILL_MAX_BYTES - named_bytes)
        if path.read_bytes() not in named_contents
    ][:DISTILL_MAX_INPUTS]
    if not survivors:
        die("nothing survived beyond the hand-named inputs, so nothing is written")

    if args.tmin:
        # Largest first: the same edge set is usually reachable from a shorter
        # input, and the bytes saved are worth the most on the biggest files.
        for path in sorted(survivors, key=lambda p: (-p.stat().st_size, p.name))[: args.tmin]:
            shrunk = staging / f"tmin-{path.name}"
            if afl_tmin(target, path, shrunk, args.tmin_timeout):
                print(f"  afl-tmin {path.name}: {path.stat().st_size} -> {shrunk.stat().st_size} bytes")
                shrunk.replace(path)
            else:
                print(f"  afl-tmin {path.name}: gave up after {args.tmin_timeout}s, keeping the original")

    kept: list[tuple[str, bytes]] = []
    rejected = 0
    for path in survivors:
        data = path.read_bytes()
        passed, output = replay(target, path)
        if not passed:
            rejected += 1
            print(f"  refusing {path.name}: it fails replay (a crash belongs in `add` beside its fix)")
            continue
        kept.append((content_name(data), data))

    target.regression_dir.mkdir(parents=True, exist_ok=True)
    previous = {path.name for path in target.distilled_inputs()}
    current = {name for name, _ in kept}
    for name in sorted(previous - current):
        (target.regression_dir / name).unlink()
    for name, data in kept:
        (target.regression_dir / name).write_bytes(data)

    total = sum(len(data) for _, data in kept)
    print(
        f"\n{target.regression_dir.relative_to(ROOT)}: {len(kept)} distilled input(s), {total} bytes "
        f"({len(current - previous)} new, {len(previous - current)} removed, {rejected} refused)"
    )
    print("review with: git status test/fuzzing/corpus; verify with: python3 scripts/fuzz.py check " + target.name)
    return 0


def command_repro(args: argparse.Namespace) -> int:
    target = resolve_targets([args.target])[0]
    ensure_built([target], need_afl=False, skip_build=args.no_build)

    command = [str(target.repro_exe)]
    if args.verbose:
        command.append("--verbose")
    command.append(str(Path(args.input).resolve()))

    print(f"$ {' '.join(command)}")
    return subprocess.run(command, cwd=ROOT).returncode


def replay(target: Target, path: Path, verbose: bool = False) -> tuple[bool, str]:
    """Replays one input, returning whether it passed and any output it produced.

    The repro executable is the same object file AFL++ fuzzes, so a pass here is
    a pass of the code that produced the input, not of a lookalike build.
    """
    command = [str(target.repro_exe)]
    if verbose:
        command.append("--verbose")
    command.append(str(path.resolve()))
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    return result.returncode == 0, (result.stdout or "") + (result.stderr or "")


def command_check(args: argparse.Namespace) -> int:
    """Replays every committed regression input, and optionally the live corpora.

    This is the part of fuzzing that belongs in CI. Fuzzing itself is unbounded
    and machine-hungry, but replaying a fixed set of inputs is neither, and it is
    what stops a fixed crash from coming back unnoticed.
    """
    targets = resolve_targets(args.targets)
    ensure_built(targets, need_afl=False, skip_build=args.no_build)
    known = read_known_failures()

    total = 0
    regressions: list[tuple[Target, Path, str]] = []
    expected_failures: list[str] = []
    fixed: list[str] = []

    for target in targets:
        inputs = target.regression_inputs()
        if args.corpus and target.corpus_dir.exists():
            inputs += sorted(path for path in target.corpus_dir.iterdir() if path.is_file())

        print(f"\n=== {target.name}: {len(inputs)} input(s) ===")
        if not inputs:
            print("  no regression inputs")
            continue

        target_regressions = 0
        for path in inputs:
            total += 1
            key = target.regression_key(path)
            passed, output = replay(target, path)

            if passed:
                if key in known:
                    fixed.append(key)
                    print(f"  FIXED {key} (delete it from known-failures.txt)")
                continue

            if key in known:
                expected_failures.append(key)
                continue

            regressions.append((target, path, output))
            target_regressions += 1
            print(f"  FAIL {path.relative_to(ROOT)}")

        if target_regressions == 0:
            print("  all passed" if not expected_failures else "  no regressions")

    print(
        f"\nreplayed {total} input(s); {len(regressions)} regressed, "
        f"{len(expected_failures)} known failing, {len(fixed)} fixed"
    )
    for key in expected_failures:
        print(f"  known failing: {key}")

    for target, path, output in regressions:
        print(f"\n--- {target.name} {path.relative_to(ROOT)} ---")
        print(output.strip() or "(no output)")
        print(f"debug with: python3 scripts/fuzz.py repro {target.name} {path.relative_to(ROOT)} --verbose")

    if fixed:
        print(
            f"\n{len(fixed)} known-failing input(s) now pass. Delete them from\n"
            f"{KNOWN_FAILURES_PATH.relative_to(ROOT)} so the list only shrinks."
        )
    return 1 if regressions or fixed else 0


def command_add(args: argparse.Namespace) -> int:
    """Copies an input into the committed regression corpus under a chosen name.

    Naming is deliberate rather than content-hashed: the point of a regression
    input is that whoever reads the directory later can tell what each one is for.
    """
    target = resolve_targets([args.target])[0]
    source = Path(args.input)
    if not source.is_file():
        die(f"no such input: {source}")

    target.regression_dir.mkdir(parents=True, exist_ok=True)
    destination = target.regression_dir / args.name
    if destination.exists() and not args.force:
        die(f"{destination.relative_to(ROOT)} already exists; pass --force to replace it")
    shutil.copyfile(source, destination)
    print(f"added {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")

    ensure_built([target], need_afl=False, skip_build=args.no_build)
    passed, output = replay(target, destination)
    print(f"replay: {'passes' if passed else 'FAILS'}")
    if not passed:
        print(output.strip())
        print("\nA failing regression input is only useful once the bug behind it is fixed;")
        print("leave it here and it will keep CI red until then.")
    return 0


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
    result = subprocess.run(command, cwd=ROOT, env=afl_env(target))
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
            "  python3 scripts/fuzz.py distill structural\n"
            "  python3 scripts/fuzz.py status\n"
            "  python3 scripts/fuzz.py check\n"
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

    distill_parser = subparsers.add_parser("distill", help="minimize the live queue into the committed corpus")
    distill_parser.add_argument("target")
    distill_parser.add_argument("-j", "--jobs", type=int, default=1, help="parallel afl-showmap tracers")
    distill_parser.add_argument("--tmin", type=int, default=0, metavar="N", help="also afl-tmin the N largest survivors")
    distill_parser.add_argument("--tmin-timeout", type=int, default=120, metavar="SECONDS", help="give up on one afl-tmin after this long")
    add_no_build(distill_parser)
    distill_parser.set_defaults(func=command_distill)

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

    check_parser = subparsers.add_parser("check", help="replay the committed regression inputs (no AFL++ needed)")
    check_parser.add_argument("targets", nargs="*", help="target names, or 'all' (the default)")
    check_parser.add_argument("--corpus", action="store_true", help="also replay the live .fuzz-out corpora")
    add_no_build(check_parser)
    check_parser.set_defaults(func=command_check)

    add_parser = subparsers.add_parser("add", help="copy an input into the committed regression corpus")
    add_parser.add_argument("target")
    add_parser.add_argument("input", help="path to the input, ideally minimized first")
    add_parser.add_argument("name", help="descriptive file name, e.g. 'sibling-each-commit-trap'")
    add_parser.add_argument("--force", action="store_true", help="replace an existing entry of that name")
    add_no_build(add_parser)
    add_parser.set_defaults(func=command_add)

    clean_parser = subparsers.add_parser("clean", help="remove corpora and fuzzer output")
    clean_parser.add_argument("targets", nargs="*", help="target names, or 'all' (the default)")
    clean_parser.set_defaults(func=command_clean)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
