#!/usr/bin/env python3
"""Discover and run native-host S-expression specs in isolated processes."""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Iterable


PROTOCOL = "roc-signals/spec-result/v2"
PASSING_STATUSES = {"passed"}
NATIVE_STATUSES = {"passed", "failed", "error"}
NATIVE_SPEC_ENTROPY_SEED = 0


@dataclass(frozen=True)
class SpecCase:
    id: str
    path: Path


@dataclass(frozen=True)
class SpecResult:
    id: str
    name: str
    status: str
    duration_ns: int
    failure: dict[str, Any] | None
    stdout: str
    stderr: str
    host_allocation_attempts: int = 0
    fault: dict[str, Any] | None = None

    @property
    def passed(self) -> bool:
        return self.status in PASSING_STATUSES


def default_jobs() -> int:
    return max(1, (os.cpu_count() or 1) // 2)


def discover_specs(spec_directory: Path) -> tuple[SpecCase, ...]:
    root = spec_directory.resolve()
    if not root.is_dir():
        raise ValueError(f"spec directory not found: {spec_directory}")

    cases: list[SpecCase] = []
    for path in root.rglob("*.scm"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        cases.append(SpecCase(relative, path))
    cases.sort(key=lambda case: case.id)
    if not cases:
        raise ValueError(f"no *.scm files found in {spec_directory}")
    return tuple(cases)


def select_specs(
    cases: Iterable[SpecCase],
    *,
    patterns: tuple[str, ...] = (),
    shard: tuple[int, int] | None = None,
) -> tuple[SpecCase, ...]:
    selected = tuple(
        case
        for case in cases
        if not patterns or any(fnmatch.fnmatchcase(case.id, pattern) for pattern in patterns)
    )
    if shard is None:
        return selected
    index, total = shard
    return tuple(case for position, case in enumerate(selected) if position % total == index)


def run_case(
    executable: Path,
    case: SpecCase,
    *,
    timeout_seconds: float,
    verbose: bool,
    worker_args: tuple[str, ...] = (),
) -> SpecResult:
    command = [
        str(executable),
        "--run-spec-json",
        "--entropy-seed",
        str(NATIVE_SPEC_ENTROPY_SEED),
    ]
    if verbose:
        command.append("--verbose")
    command.extend(worker_args)
    command.append(str(case.path))
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return synthetic_result(
            case,
            "timed_out",
            started,
            "timeout",
            f"test exceeded {timeout_seconds:g} seconds",
            stdout=_timeout_text(exc.stdout),
            stderr=_timeout_text(exc.stderr),
        )
    except OSError as exc:
        return synthetic_result(case, "crashed", started, "spawn", str(exc))

    duration_ns = time.monotonic_ns() - started
    stdout = completed.stdout.strip()
    if not stdout:
        return synthetic_result(
            case,
            "crashed",
            started,
            "missing_result",
            f"worker exited with code {completed.returncode} without a JSON result",
            stderr=completed.stderr,
        )
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        return synthetic_result(
            case,
            "protocol_error",
            started,
            "invalid_json",
            str(exc),
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    if not isinstance(payload, dict) or payload.get("protocol") != PROTOCOL:
        return synthetic_result(
            case,
            "protocol_error",
            started,
            "invalid_protocol",
            f"worker did not emit {PROTOCOL}",
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    status = payload.get("status")
    if status not in NATIVE_STATUSES:
        return synthetic_result(
            case,
            "protocol_error",
            started,
            "invalid_status",
            f"worker emitted invalid status: {status!r}",
            stdout=completed.stdout,
            stderr=completed.stderr,
        )

    failure = payload.get("failure")
    if failure is not None and not isinstance(failure, dict):
        return synthetic_result(
            case,
            "protocol_error",
            started,
            "invalid_failure",
            "worker failure must be an object or null",
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    host_allocation_attempts = payload.get("host_allocation_attempts", 0)
    if not isinstance(host_allocation_attempts, int) or host_allocation_attempts < 0:
        return synthetic_result(case, "protocol_error", started, "invalid_allocation_count", "worker host_allocation_attempts must be a non-negative integer", stdout=completed.stdout, stderr=completed.stderr)
    fault = payload.get("fault")
    if fault is not None and not isinstance(fault, dict):
        return synthetic_result(case, "protocol_error", started, "invalid_fault", "worker fault must be an object or null", stdout=completed.stdout, stderr=completed.stderr)
    if "--fail-on-allocation" in worker_args:
        expected_allocation = int(worker_args[worker_args.index("--fail-on-allocation") + 1])
        if fault is None or fault.get("allocation") != expected_allocation:
            return synthetic_result(case, "protocol_error", started, "invalid_fault", "worker did not report the selected allocation coordinate", stdout=completed.stdout, stderr=completed.stderr)
        if fault.get("outcome") not in {"continued", "refused_then_retried", "skipped_roc", "skipped_fatal_command"}:
            return synthetic_result(case, "protocol_error", started, "invalid_fault", "worker reported an unknown allocation outcome", stdout=completed.stdout, stderr=completed.stderr)
    expected_exit = 0 if status == "passed" else 1 if status == "failed" else 2
    if completed.returncode != expected_exit:
        return synthetic_result(
            case,
            "protocol_error",
            started,
            "exit_status_mismatch",
            f"worker status {status!r} conflicts with exit code {completed.returncode}",
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    return SpecResult(
        id=case.id,
        name=str(payload.get("name") or case.id),
        status=status,
        duration_ns=int(payload.get("duration_ns") or duration_ns),
        failure=failure,
        stdout=completed.stdout,
        stderr=completed.stderr,
        host_allocation_attempts=host_allocation_attempts,
        fault=fault,
    )


def synthetic_result(
    case: SpecCase,
    status: str,
    started_ns: int,
    kind: str,
    message: str,
    *,
    stdout: str = "",
    stderr: str = "",
) -> SpecResult:
    return SpecResult(
        id=case.id,
        name=case.id,
        status=status,
        duration_ns=time.monotonic_ns() - started_ns,
        failure={"phase": "worker", "kind": kind, "message": message},
        stdout=stdout,
        stderr=stderr,
    )


def run_suite(
    executable: Path,
    spec_directory: Path,
    *,
    jobs: int | None = None,
    patterns: tuple[str, ...] = (),
    shard: tuple[int, int] | None = None,
    fail_fast: bool = False,
    timeout_seconds: float = 30.0,
    verbose: bool = False,
    print_progress: bool = True,
    worker_args: tuple[str, ...] = (),
    serial_patterns: tuple[str, ...] = (),
    timeout_overrides: dict[str, float] | None = None,
) -> tuple[SpecResult, ...]:
    executable = executable.resolve()
    if not executable.is_file():
        raise ValueError(f"native app executable not found: {executable}")
    cases = select_specs(discover_specs(spec_directory), patterns=patterns, shard=shard)
    if not cases:
        raise ValueError("no specs matched the requested filters and shard")
    parallel_cases = tuple(case for case in cases if not any(fnmatch.fnmatchcase(case.id, pattern) for pattern in serial_patterns))
    serial_cases = tuple(case for case in cases if any(fnmatch.fnmatchcase(case.id, pattern) for pattern in serial_patterns))
    timeout_overrides = timeout_overrides or {}

    def timeout_for(case: SpecCase) -> float:
        return timeout_overrides.get(case.id, timeout_seconds)

    worker_count = max(1, jobs if jobs is not None else default_jobs())
    worker_count = min(worker_count, len(parallel_cases)) if parallel_cases else 1

    results: list[SpecResult] = []
    pending_cases = iter(parallel_cases)
    running: dict[Future[SpecResult], SpecCase] = {}
    stopped = False
    with ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="native-spec") as pool:
        for _ in range(worker_count):
            case = next(pending_cases, None)
            if case is None:
                break
            running[pool.submit(run_case, executable, case, timeout_seconds=timeout_for(case), verbose=verbose, worker_args=worker_args)] = case

        while running:
            completed_futures, _ = wait(running, return_when=FIRST_COMPLETED)
            for future in completed_futures:
                case = running.pop(future)
                try:
                    result = future.result()
                except BaseException as exc:
                    result = synthetic_result(case, "crashed", time.monotonic_ns(), "controller", repr(exc))
                results.append(result)
                if print_progress:
                    marker = "PASS" if result.passed else result.status.upper()
                    print(f"[{marker}] {result.id} ({result.duration_ns / 1_000_000:.1f} ms)", flush=True)
                if fail_fast and not result.passed:
                    stopped = True
                if not stopped:
                    next_case = next(pending_cases, None)
                    if next_case is not None:
                        running[pool.submit(run_case, executable, next_case, timeout_seconds=timeout_for(next_case), verbose=verbose, worker_args=worker_args)] = next_case

    # Memory-heavy cases run without overlapping worker processes. Keeping this
    # separate from worker-count policy preserves parallelism for ordinary specs
    # while bounding the peak retained graph and simulated DOM memory.
    if not stopped:
        for case in serial_cases:
            result = run_case(executable, case, timeout_seconds=timeout_for(case), verbose=verbose, worker_args=worker_args)
            results.append(result)
            if print_progress:
                marker = "PASS" if result.passed else result.status.upper()
                print(f"[{marker}] {result.id} ({result.duration_ns / 1_000_000:.1f} ms)", flush=True)
            if fail_fast and not result.passed:
                break

    results.sort(key=lambda result: result.id)
    return tuple(results)


def run_fault_suite(
    executable: Path,
    spec_directory: Path,
    *,
    jobs: int | None = None,
    patterns: tuple[str, ...] = (),
    shard: tuple[int, int] | None = None,
    fail_fast: bool = False,
    timeout_seconds: float = 30.0,
    verbose: bool = False,
) -> tuple[SpecResult, ...]:
    """Run clean specs, then replay every reported host allocation coordinate."""
    probes = run_suite(
        executable,
        spec_directory,
        jobs=jobs,
        patterns=patterns,
        shard=shard,
        fail_fast=fail_fast,
        timeout_seconds=timeout_seconds,
        verbose=verbose,
        print_progress=True,
    )
    if not all(result.passed for result in probes):
        return probes

    source_cases = {case.id: case for case in select_specs(discover_specs(spec_directory), patterns=patterns, shard=shard)}
    jobs_to_run: list[tuple[SpecCase, tuple[str, ...], str]] = []
    for probe in probes:
        for allocation in range(1, probe.host_allocation_attempts + 1):
            case = SpecCase(f"{probe.id}::allocation@{allocation}", source_cases[probe.id].path)
            args = ("--fail-on-allocation", str(allocation))
            replay = f"{executable} --run-spec-json --entropy-seed {NATIVE_SPEC_ENTROPY_SEED} {' '.join(args)} {case.path}"
            jobs_to_run.append((case, args, replay))
    if not jobs_to_run:
        raise ValueError("clean specs reported no host allocation opportunities")

    worker_count = min(max(1, jobs if jobs is not None else default_jobs()), len(jobs_to_run))
    results: list[SpecResult] = list(probes)
    pending = iter(jobs_to_run)
    running: dict[Future[SpecResult], tuple[SpecCase, str]] = {}
    stopped = False
    with ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="native-fault") as pool:
        for _ in range(worker_count):
            item = next(pending, None)
            if item is None:
                break
            case, args, replay = item
            running[pool.submit(run_case, executable, case, timeout_seconds=timeout_seconds, verbose=verbose, worker_args=args)] = (case, replay)
        while running:
            completed_futures, _ = wait(running, return_when=FIRST_COMPLETED)
            for future in completed_futures:
                case, replay = running.pop(future)
                try:
                    result = future.result()
                except BaseException as exc:
                    result = synthetic_result(case, "crashed", time.monotonic_ns(), "controller", repr(exc))
                if not result.passed and result.failure is not None:
                    result.failure["replay"] = replay
                results.append(result)
                if not result.passed:
                    print(f"[{result.status.upper()}] {result.id} ({result.duration_ns / 1_000_000:.1f} ms)", flush=True)
                if fail_fast and not result.passed:
                    stopped = True
                if not stopped:
                    item = next(pending, None)
                    if item is not None:
                        next_case, args, next_replay = item
                        running[pool.submit(run_case, executable, next_case, timeout_seconds=timeout_seconds, verbose=verbose, worker_args=args)] = (next_case, next_replay)
    results.sort(key=lambda result: result.id)
    return tuple(results)


def print_summary(results: tuple[SpecResult, ...]) -> None:
    failures = tuple(result for result in results if not result.passed)
    for result in failures:
        print(f"\nFAIL: {result.id} — {result.name}")
        if result.failure:
            print(f"  {result.failure.get('phase', 'test')}/{result.failure.get('kind', 'failure')}: {result.failure.get('message', '')}")
            if result.failure.get("replay"):
                print(f"  replay: {result.failure['replay']}")
        if result.stderr.strip():
            print(result.stderr.rstrip())
        if result.status == "protocol_error" and result.stdout.strip():
            print("  worker stdout:")
            print(result.stdout.rstrip())

    passed = sum(result.passed for result in results)
    elapsed_ns = sum(result.duration_ns for result in results)
    print(f"\n{passed} passed, {len(results) - passed} failed, {len(results)} total ({elapsed_ns / 1_000_000_000:.2f}s worker time)")
    outcomes: dict[str, int] = {}
    for result in results:
        if result.fault is not None:
            outcome = str(result.fault.get("outcome", "unknown"))
            outcomes[outcome] = outcomes.get(outcome, 0) + 1
    if outcomes:
        print("Fault outcomes: " + ", ".join(f"{name}={count}" for name, count in sorted(outcomes.items())))


def parse_shard(value: str) -> tuple[int, int]:
    try:
        current_text, total_text = value.split("/", 1)
        current = int(current_text)
        total = int(total_text)
    except (ValueError, TypeError) as exc:
        raise argparse.ArgumentTypeError("shard must be CURRENT/TOTAL") from exc
    if total < 1 or current < 1 or current > total:
        raise argparse.ArgumentTypeError("shard must satisfy 1 <= CURRENT <= TOTAL")
    return current - 1, total


def parse_jobs(value: str) -> int | None:
    if value == "auto":
        return None
    try:
        jobs = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("jobs must be auto or a positive integer") from exc
    if jobs < 1:
        raise argparse.ArgumentTypeError("jobs must be auto or a positive integer")
    return jobs


def _timeout_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    return value.decode(errors="replace") if isinstance(value, bytes) else value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("spec_directory", type=Path)
    parser.add_argument("--jobs", type=parse_jobs, default=None, metavar="auto|N")
    parser.add_argument("--filter", action="append", default=[], metavar="GLOB")
    parser.add_argument("--shard", type=parse_shard, metavar="CURRENT/TOTAL")
    parser.add_argument("--fail-fast", action="store_true")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--sweep-allocations", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    try:
        cases = select_specs(discover_specs(args.spec_directory), patterns=tuple(args.filter), shard=args.shard)
        if args.list:
            for case in cases:
                print(case.id)
            return 0 if cases else 2
        runner = run_fault_suite if args.sweep_allocations else run_suite
        results = runner(
            args.executable,
            args.spec_directory,
            jobs=args.jobs,
            patterns=tuple(args.filter),
            shard=args.shard,
            fail_fast=args.fail_fast,
            timeout_seconds=args.timeout_seconds,
            verbose=args.verbose,
        )
    except ValueError as exc:
        parser.error(str(exc))
    print_summary(results)
    return 0 if all(result.passed for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
