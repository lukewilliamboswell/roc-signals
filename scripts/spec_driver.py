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


PROTOCOL = "roc-signals/spec-result/v1"
PASSING_STATUSES = {"passed"}
NATIVE_STATUSES = {"passed", "failed", "error"}


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
) -> SpecResult:
    command = [str(executable), "--run-spec-json"]
    if verbose:
        command.append("--verbose")
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
) -> tuple[SpecResult, ...]:
    executable = executable.resolve()
    if not executable.is_file():
        raise ValueError(f"native app executable not found: {executable}")
    cases = select_specs(discover_specs(spec_directory), patterns=patterns, shard=shard)
    if not cases:
        raise ValueError("no specs matched the requested filters and shard")
    worker_count = max(1, jobs if jobs is not None else default_jobs())
    worker_count = min(worker_count, len(cases))

    results: list[SpecResult] = []
    pending_cases = iter(cases)
    running: dict[Future[SpecResult], SpecCase] = {}
    stopped = False
    with ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="native-spec") as pool:
        for _ in range(worker_count):
            case = next(pending_cases, None)
            if case is None:
                break
            running[pool.submit(run_case, executable, case, timeout_seconds=timeout_seconds, verbose=verbose)] = case

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
                        running[pool.submit(run_case, executable, next_case, timeout_seconds=timeout_seconds, verbose=verbose)] = next_case

    results.sort(key=lambda result: result.id)
    return tuple(results)


def print_summary(results: tuple[SpecResult, ...]) -> None:
    failures = tuple(result for result in results if not result.passed)
    for result in failures:
        print(f"\nFAIL: {result.id} — {result.name}")
        if result.failure:
            print(f"  {result.failure.get('phase', 'test')}/{result.failure.get('kind', 'failure')}: {result.failure.get('message', '')}")
        if result.stderr.strip():
            print(result.stderr.rstrip())
        if result.status == "protocol_error" and result.stdout.strip():
            print("  worker stdout:")
            print(result.stdout.rstrip())

    passed = sum(result.passed for result in results)
    elapsed_ns = sum(result.duration_ns for result in results)
    print(f"\n{passed} passed, {len(results) - passed} failed, {len(results)} total ({elapsed_ns / 1_000_000_000:.2f}s worker time)")


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
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    try:
        cases = select_specs(discover_specs(args.spec_directory), patterns=tuple(args.filter), shard=args.shard)
        if args.list:
            for case in cases:
                print(case.id)
            return 0 if cases else 2
        results = run_suite(
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
