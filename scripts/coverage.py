#!/usr/bin/env python3
"""Native host coverage analysis for Roc Signals.

Runs the native Zig test coverage step and reports merged line coverage across
the shared signals tests and the native host tests.
"""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
KCOV_OUTPUT_DIR = ROOT / "kcov-output" / "native-host"
COVERAGE_RUNNERS = ("signals_shared_coverage", "signals_host_coverage")


@dataclass
class FileCoverage:
    rel_path: str
    hits: dict[int, int] = field(default_factory=dict)
    fallback_covered: int = 0
    fallback_total: int = 0

    @property
    def total_lines(self) -> int:
        if self.hits:
            return len(self.hits)
        return self.fallback_total

    @property
    def covered_lines(self) -> int:
        if self.hits:
            return sum(1 for hits in self.hits.values() if hits > 0)
        return self.fallback_covered

    @property
    def uncovered_lines(self) -> int:
        return max(0, self.total_lines - self.covered_lines)

    @property
    def percent_covered(self) -> float:
        if self.total_lines == 0:
            return 0.0
        return self.covered_lines / self.total_lines * 100.0


@dataclass(frozen=True)
class FileThreshold:
    pattern: str
    minimum: float


@dataclass
class FileThresholdResult:
    threshold: FileThreshold
    matched: list[FileCoverage]
    failed: list[FileCoverage]

    @property
    def passed(self) -> bool:
        return bool(self.matched) and not self.failed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run and inspect native host kcov coverage.",
        epilog=(
            "examples:\n"
            "  %(prog)s\n"
            "  %(prog)s --use-last-run --top 20\n"
            "  %(prog)s --use-last-run --format lines --file engine --context 5\n"
            "  %(prog)s --use-last-run --format json --top 10\n"
            "  %(prog)s --min 35\n"
            "  %(prog)s --min 84 --min-file src/signals/engine.zig=67.5\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--use-last-run",
        action="store_true",
        help="Skip rebuilding and analyze existing kcov-output/native-host data.",
    )
    parser.add_argument(
        "--format",
        "-f",
        choices=("summary", "lines", "json"),
        default="summary",
        help="Output format. Defaults to summary.",
    )
    parser.add_argument(
        "--file",
        metavar="PATTERN",
        help="Only include files whose path contains PATTERN, case-insensitive.",
    )
    parser.add_argument(
        "--top",
        metavar="N",
        type=int,
        help="Show only the top N files ranked by uncovered line count.",
    )
    parser.add_argument(
        "--context",
        metavar="N",
        type=int,
        default=2,
        help="Source context lines around uncovered ranges for --format lines.",
    )
    parser.add_argument(
        "--min",
        metavar="PERCENT",
        type=float,
        help="Fail if merged coverage is below PERCENT.",
    )
    parser.add_argument(
        "--min-file",
        metavar="PATTERN=PERCENT",
        action="append",
        default=[],
        help=(
            "Fail if any normalized relative file path containing PATTERN is below PERCENT. "
            "May be repeated. Fails if PATTERN matches no files."
        ),
    )
    return parser.parse_args()


def check_platform() -> None:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin":
        return
    if system == "Linux" and machine in {"aarch64", "arm64"}:
        return

    print(
        "native host coverage is supported on macOS and Linux arm64.\n"
        "Linux x86_64 is currently disabled because kcov cannot reliably read "
        "Zig DWARF there.",
        file=sys.stderr,
    )
    raise SystemExit(1)


def run_coverage() -> None:
    if KCOV_OUTPUT_DIR.exists():
        shutil.rmtree(KCOV_OUTPUT_DIR)
    result = subprocess.run(["zig", "build", "run-coverage-native-host"], cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def load_json(path: Path) -> object:
    if not path.exists():
        print(f"missing coverage data: {path}", file=sys.stderr)
        raise SystemExit(1)
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def normalize_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    root = str(ROOT).replace("\\", "/")
    if normalized.startswith(root + "/"):
        return normalized[len(root) + 1 :]
    src_marker = "/src/"
    index = normalized.find(src_marker)
    if index != -1:
        return normalized[index + 1 :]
    return normalized


def should_include_path(rel_path: str, file_pattern: str | None) -> bool:
    if not rel_path.startswith("src/"):
        return False
    if file_pattern is None:
        return True
    return file_pattern.lower() in rel_path.lower()


def parse_file_threshold(raw: str) -> FileThreshold:
    if "=" not in raw:
        raise SystemExit(f"invalid --min-file value {raw!r}; expected PATTERN=PERCENT")

    pattern, raw_minimum = raw.split("=", 1)
    pattern = normalize_path(pattern.strip())
    if not pattern:
        raise SystemExit(f"invalid --min-file value {raw!r}; PATTERN cannot be empty")

    try:
        minimum = float(raw_minimum)
    except ValueError:
        raise SystemExit(
            f"invalid --min-file value {raw!r}; PERCENT must be a number"
        ) from None
    if minimum < 0 or minimum > 100:
        raise SystemExit(
            f"invalid --min-file value {raw!r}; PERCENT must be between 0 and 100"
        )

    return FileThreshold(pattern=pattern, minimum=minimum)


def parse_count(value: object) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value)
    return 0


def parse_hit_count(value: object) -> int:
    if isinstance(value, int):
        return value
    if not isinstance(value, str):
        return 0
    hits = value.split("/", 1)[0]
    return int(hits)


def basename_counts(summary_files: list[dict[str, object]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for entry in summary_files:
        file_name = str(entry.get("file", ""))
        basename = Path(file_name).name
        counts[basename] = counts.get(basename, 0) + 1
    return counts


def find_line_data_key(
    rel_path: str,
    full_path: str,
    line_data: dict[str, dict[str, object]],
    counts: dict[str, int],
) -> str | None:
    normalized_full = full_path.replace("\\", "/")
    rel_path = rel_path.replace("\\", "/")

    suffix_matches = [
        key
        for key in line_data
        if "/" in key and (rel_path.endswith(key) or normalized_full.endswith(key))
    ]
    if suffix_matches:
        return max(suffix_matches, key=len)

    basename = Path(rel_path).name
    if counts.get(basename, 0) == 1 and basename in line_data:
        return basename

    exact_matches = [
        key
        for key in line_data
        if rel_path.endswith(key) or normalized_full.endswith(key)
    ]
    if exact_matches:
        return max(exact_matches, key=len)

    return None


def merge_coverage(file_pattern: str | None) -> dict[str, FileCoverage]:
    merged: dict[str, FileCoverage] = {}

    for runner in COVERAGE_RUNNERS:
        runner_dir = KCOV_OUTPUT_DIR / runner
        summary = load_json(runner_dir / "coverage.json")
        codecov = load_json(runner_dir / "codecov.json")

        if not isinstance(summary, dict) or not isinstance(codecov, dict):
            raise SystemExit(f"invalid kcov output in {runner_dir}")

        summary_files = summary.get("files", [])
        raw_line_data = codecov.get("coverage", {})
        if not isinstance(summary_files, list) or not isinstance(raw_line_data, dict):
            raise SystemExit(f"invalid kcov output in {runner_dir}")

        line_data = {
            str(path).replace("\\", "/"): data
            for path, data in raw_line_data.items()
            if isinstance(data, dict)
        }
        counts = basename_counts(summary_files)

        for entry in summary_files:
            if not isinstance(entry, dict):
                continue
            full_path = str(entry.get("file", ""))
            rel_path = normalize_path(full_path)
            if not should_include_path(rel_path, file_pattern):
                continue

            file_cov = merged.setdefault(rel_path, FileCoverage(rel_path))
            covered = parse_count(entry.get("covered_lines", 0))
            total = parse_count(entry.get("total_lines", 0))
            file_cov.fallback_covered = max(file_cov.fallback_covered, covered)
            file_cov.fallback_total = max(file_cov.fallback_total, total)

            key = find_line_data_key(rel_path, full_path, line_data, counts)
            if key is None:
                continue

            for raw_line, raw_hits in line_data[key].items():
                line_num = int(raw_line)
                hits = parse_hit_count(raw_hits)
                file_cov.hits[line_num] = max(file_cov.hits.get(line_num, 0), hits)

    return merged


def sorted_files(files: dict[str, FileCoverage], top: int | None) -> list[FileCoverage]:
    result = sorted(
        files.values(),
        key=lambda item: (item.uncovered_lines, item.total_lines, item.rel_path),
        reverse=True,
    )
    if top is not None:
        return result[:top]
    return result


def totals(files: list[FileCoverage]) -> tuple[int, int, float]:
    total = sum(file.total_lines for file in files)
    covered = sum(file.covered_lines for file in files)
    percent = covered / total * 100.0 if total else 0.0
    return covered, total, percent


def evaluate_file_thresholds(
    files_by_path: dict[str, FileCoverage],
    raw_thresholds: list[str],
) -> list[FileThresholdResult]:
    results: list[FileThresholdResult] = []
    for raw in raw_thresholds:
        threshold = parse_file_threshold(raw)
        matched = [
            file_cov
            for path, file_cov in files_by_path.items()
            if threshold.pattern.lower() in path.lower()
        ]
        matched.sort(key=lambda item: item.rel_path)
        failed = [
            file_cov
            for file_cov in matched
            if file_cov.percent_covered < threshold.minimum
        ]
        results.append(
            FileThresholdResult(
                threshold=threshold,
                matched=matched,
                failed=failed,
            )
        )
    return results


def format_file_threshold_failures(results: list[FileThresholdResult]) -> str:
    lines: list[str] = []
    for result in results:
        threshold = result.threshold
        if not result.matched:
            lines.append(
                f"file coverage pattern {threshold.pattern!r} matched no files"
            )
            continue

        for file_cov in result.failed:
            lines.append(
                f"{file_cov.rel_path} coverage {file_cov.percent_covered:.2f}% "
                f"is below required file minimum {threshold.minimum:.2f}%"
            )
    return "\n".join(lines)


def uncovered_ranges(file_cov: FileCoverage) -> list[tuple[int, int]]:
    uncovered = sorted(line for line, hits in file_cov.hits.items() if hits == 0)
    if not uncovered:
        return []

    ranges: list[tuple[int, int]] = []
    start = uncovered[0]
    previous = uncovered[0]
    for line in uncovered[1:]:
        if line == previous + 1:
            previous = line
            continue
        ranges.append((start, previous))
        start = line
        previous = line
    ranges.append((start, previous))
    return ranges


def format_summary(files: list[FileCoverage], overall_files: list[FileCoverage], top: int | None) -> str:
    covered, total, percent = totals(overall_files)
    lines = [f"Native host coverage: {percent:.2f}% ({covered}/{total} lines)", ""]
    if top is not None:
        lines.append(f"Showing top {top} files by uncovered line count.")
        lines.append("")
    header = f"{'File':<42} {'Coverage':>8} {'Covered':>8} {'Total':>7} {'Uncovered':>10}"
    lines.append(header)
    lines.append("-" * len(header))

    for file_cov in files:
        lines.append(
            f"{file_cov.rel_path:<42} "
            f"{file_cov.percent_covered:>7.2f}% "
            f"{file_cov.covered_lines:>8} "
            f"{file_cov.total_lines:>7} "
            f"{file_cov.uncovered_lines:>10}"
        )

    return "\n".join(lines)


def format_lines(
    files: list[FileCoverage],
    overall_files: list[FileCoverage],
    context: int,
    top: int | None,
) -> str:
    covered, total, percent = totals(overall_files)
    sections = [f"Native host coverage: {percent:.2f}% ({covered}/{total} lines)", ""]
    if top is not None:
        sections.append(f"Showing top {top} files by uncovered line count.")
        sections.append("")

    for file_cov in files:
        ranges = uncovered_ranges(file_cov)
        if not ranges:
            continue

        source_path = ROOT / file_cov.rel_path
        if not source_path.exists():
            continue

        source_lines = source_path.read_text(encoding="utf-8").splitlines()
        sections.append(
            f"## {file_cov.rel_path} - {file_cov.percent_covered:.2f}% covered "
            f"({file_cov.uncovered_lines} uncovered lines)"
        )
        sections.append("")

        for start, end in ranges:
            context_start = max(1, start - context)
            context_end = min(len(source_lines), end + context)
            sections.append(f"### Lines {start}-{end} (uncovered)")
            sections.append("```zig")
            for line_num in range(context_start, context_end + 1):
                prefix = ">" if start <= line_num <= end else " "
                sections.append(f"{prefix} {line_num:>5} | {source_lines[line_num - 1]}")
            sections.append("```")
            sections.append("")

    return "\n".join(sections).rstrip()


def format_json(
    files: list[FileCoverage],
    overall_files: list[FileCoverage],
    top: int | None,
    file_thresholds: list[FileThresholdResult],
) -> str:
    covered, total, percent = totals(overall_files)
    result = {
        "overall": {
            "percent_covered": round(percent, 2),
            "covered_lines": covered,
            "total_lines": total,
            "displayed_files": len(files),
            "top": top,
        },
        "files": [
            {
                "file": file_cov.rel_path,
                "percent_covered": round(file_cov.percent_covered, 2),
                "covered_lines": file_cov.covered_lines,
                "total_lines": file_cov.total_lines,
                "uncovered_lines": file_cov.uncovered_lines,
                "uncovered_ranges": [
                    {"start": start, "end": end}
                    for start, end in uncovered_ranges(file_cov)
                ],
            }
            for file_cov in files
        ],
        "file_thresholds": [
            {
                "pattern": threshold_result.threshold.pattern,
                "minimum": threshold_result.threshold.minimum,
                "passed": threshold_result.passed,
                "matched_files": [
                    file_cov.rel_path for file_cov in threshold_result.matched
                ],
                "failed_files": [
                    {
                        "file": file_cov.rel_path,
                        "percent_covered": round(file_cov.percent_covered, 2),
                        "covered_lines": file_cov.covered_lines,
                        "total_lines": file_cov.total_lines,
                        "uncovered_lines": file_cov.uncovered_lines,
                    }
                    for file_cov in threshold_result.failed
                ],
            }
            for threshold_result in file_thresholds
        ],
    }
    return json.dumps(result, indent=2)


def main() -> int:
    args = parse_args()

    if not args.use_last_run:
        check_platform()
        run_coverage()

    files_by_path = merge_coverage(args.file)
    overall_files = list(files_by_path.values())
    files = sorted_files(files_by_path, args.top)
    covered, total, percent = totals(overall_files)
    file_thresholds = evaluate_file_thresholds(files_by_path, args.min_file)

    if args.format == "summary":
        print(format_summary(files, overall_files, args.top))
    elif args.format == "lines":
        print(format_lines(files, overall_files, args.context, args.top))
    else:
        print(format_json(files, overall_files, args.top, file_thresholds))

    failed = False
    if args.min is not None and percent < args.min:
        print(
            f"\ncoverage {percent:.2f}% is below required minimum {args.min:.2f}%",
            file=sys.stderr,
        )
        failed = True

    file_threshold_failures = format_file_threshold_failures(file_thresholds)
    if file_threshold_failures:
        print(f"\n{file_threshold_failures}", file=sys.stderr)
        failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
