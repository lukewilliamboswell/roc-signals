#!/usr/bin/env python3
"""Measure production Wasm sizes for a fixed fixture set and gate them.

The measurement builds the ordinary ReleaseSmall browser host, copies the
platform into an isolated directory so concurrent builds cannot overwrite each
other's linked host, rebinds each fixture to that copy, and builds it with the
production application flags. Compression is fixed to Node's zlib (gzip level
9, Brotli quality 11) because different zlib implementations produce different
sizes at the same level.

Modes:
  measure (default)      build, record `.test-out/size/<label>/report.json`,
                         print a table
  --check                measure, then fail if a fixture exceeds
                         `test/size/budgets.toml`
  --symbols              also build a named host object companion and record
                         helper family counts and the largest function bodies
  --write-budgets REPORT regenerate `test/size/budgets.toml` from a report
  --compare A B          print before/after tables from two reports
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bundle_browser import runtime_files  # noqa: E402
from toolchain import development_pin, replace_platform, verify_compiler  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SIZE_DIR = ROOT / "test" / "size"
FIXTURES_MANIFEST = SIZE_DIR / "fixtures.toml"
BUDGETS_PATH = SIZE_DIR / "budgets.toml"
OUTPUT_ROOT = ROOT / ".test-out" / "size"
COMPRESS_SCRIPT = ROOT / "scripts" / "browser" / "compress_sizes.mjs"
HOST_OBJECT = ROOT / "platform-web" / "targets" / "wasm32" / "host.wasm"
HOST_BUILD = ["zig", "build", "build-wasm-host", "-Doptimize=ReleaseSmall"]
APP_FLAGS = ["--target=wasm32", "--opt=size", "--no-cache"]
BUDGET_HEADROOM_PERCENT = 1.0
GATED_METRICS = ("raw", "gzip")
FUNC_RE = re.compile(r"^ - func\[(\d+)\] size=(\d+)(?: <(.*)>)?$")
GENERIC_ARGS_RE = re.compile(r"\(.*\)")
ANON_RE = re.compile(r"__anon_\d+")
STRUCT_RE = re.compile(r"__struct_\d+")


@dataclass(frozen=True)
class Fixture:
    name: str
    source: Path
    shape: str


def load_fixtures() -> tuple[Fixture, ...]:
    manifest = tomllib.loads(FIXTURES_MANIFEST.read_text(encoding="utf-8"))
    fixtures = tuple(
        Fixture(name=str(raw["name"]), source=Path(str(raw["source"])), shape=str(raw.get("shape", "")))
        for raw in manifest["fixtures"]
    )
    names = [fixture.name for fixture in fixtures]
    if len(set(names)) != len(names):
        raise SystemExit("fixtures.toml names must be unique")
    return fixtures


def run(command: list[str | Path], *, cwd: Path = ROOT) -> None:
    print("==> " + " ".join(str(part) for part in command), file=sys.stderr, flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True)


def capture(command: list[str | Path], *, cwd: Path = ROOT) -> str:
    return subprocess.check_output([str(part) for part in command], cwd=cwd, text=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


SECTION_NAMES = {
    0: "custom", 1: "type", 2: "import", 3: "function", 4: "table", 5: "memory", 6: "global",
    7: "export", 8: "start", 9: "element", 10: "code", 11: "data", 12: "datacount", 13: "tag",
}


def read_leb128(data: bytes, offset: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return result, offset


def wasm_sections(data: bytes) -> dict[str, int]:
    """Payload byte size per section, with custom sections summed.

    This walks the binary directly so the size gate needs no wabt install;
    the figures match `wasm-objdump -h`.
    """
    if data[:8] != b"\0asm\1\0\0\0":
        raise SystemExit("not a Wasm 1.0 binary")
    sections: dict[str, int] = {}
    offset = 8
    while offset < len(data):
        kind = data[offset]
        size, offset = read_leb128(data, offset + 1)
        name = SECTION_NAMES.get(kind, f"section{kind}")
        sections[name] = sections.get(name, 0) + size
        offset += size
    if offset != len(data):
        raise SystemExit("truncated Wasm section")
    if "code" not in sections:
        raise SystemExit("Wasm binary has no code section")
    return sections


def compressed_sizes(paths: list[Path]) -> dict:
    return json.loads(capture(["node", COMPRESS_SCRIPT, *paths]))


def symbol_family(name: str) -> str:
    """Collapse one instantiation's name to its logical helper family."""
    family = ANON_RE.sub("", STRUCT_RE.sub("", name))
    while True:
        collapsed = GENERIC_ARGS_RE.sub("", family)
        if collapsed == family:
            return family.strip("._")
        family = collapsed


def symbol_inventory(path: Path, largest: int = 10) -> dict:
    """Helper family counts and largest bodies from a named host object.

    Roc's final link drops the name section, so attribution reads the
    unstripped relocatable host object rather than the linked application.
    Its body sizes are pre-relocation and differ slightly from production.
    """
    functions: list[tuple[int, str]] = []
    for line in capture(["wasm-objdump", "-x", "-j", "Code", path]).splitlines():
        match = FUNC_RE.match(line)
        if match:
            functions.append((int(match.group(2)), match.group(3) or f"func[{match.group(1)}]"))
    counts: Counter[str] = Counter()
    bytes_by_family: Counter[str] = Counter()
    for size, name in functions:
        family = symbol_family(name)
        counts[family] += 1
        bytes_by_family[family] += size
    families = [
        {"family": family, "bodies": count, "bytes": bytes_by_family[family]}
        for family, count in counts.items()
        if count > 1
    ]
    families.sort(key=lambda entry: (-entry["bytes"], entry["family"]))
    top = sorted(functions, key=lambda entry: (-entry[0], entry[1]))[:largest]
    return {
        "note": "unstripped host object built with -Dstrip=false; production artifact sizes remain authoritative",
        "function_count": len(functions),
        "named_function_count": sum(1 for _, name in functions if not name.startswith("func[")),
        "repeated_families": families[:40],
        "largest_bodies": [{"bytes": size, "name": name} for size, name in top],
    }


def git_revision() -> tuple[str, list[str]]:
    revision = capture(["git", "rev-parse", "HEAD"]).strip()
    dirty = [line for line in capture(["git", "status", "--porcelain"]).splitlines() if line.strip()]
    return revision, dirty


def build_host(*, named: bool) -> None:
    command = list(HOST_BUILD)
    if named:
        command.append("-Dstrip=false")
    run(command)


def prepare_platform(destination: Path, host_object: Path | None = None) -> Path:
    shutil.copytree(ROOT / "platform-web", destination, dirs_exist_ok=True)
    if host_object is not None:
        shutil.copy2(host_object, destination / "targets" / "wasm32" / "host.wasm")
    return destination / "main.roc"


def build_fixture(roc_bin: str, fixture: Fixture, platform_manifest: Path, source_root: Path, output: Path) -> None:
    source_dir = source_root / fixture.name
    shutil.copytree(ROOT / fixture.source.parent, source_dir, dirs_exist_ok=True)
    app = source_dir / fixture.source.name
    app.write_text(replace_platform(app.read_text(encoding="utf-8"), str(platform_manifest.resolve())), encoding="utf-8")
    run([roc_bin, "build", *APP_FLAGS, f"--output={output}", app])


def measure(args: argparse.Namespace) -> dict:
    fixtures = load_fixtures()
    pin = development_pin(ROOT)
    verify_compiler(args.roc_bin, pin)
    roc_version = capture([args.roc_bin, "version"]).strip()
    zig_version = capture(["zig", "version"]).strip()
    node_version = capture(["node", "--version"]).strip()
    revision, dirty = git_revision()

    out = OUTPUT_ROOT / args.label
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    named_host: Path | None = None
    if args.symbols:
        # Build the named companion first so the production build below leaves
        # the stripped host in the source tree.
        build_host(named=True)
        named_host = out / "host-named.wasm"
        shutil.copy2(HOST_OBJECT, named_host)
    if not args.skip_host_build:
        build_host(named=False)
    host_object = out / "host.wasm"
    shutil.copy2(HOST_OBJECT, host_object)

    platform_manifest = prepare_platform(out / "platform")

    artifacts: list[Path] = []
    results: list[dict] = []
    for fixture in fixtures:
        output = out / f"{fixture.name}.wasm"
        build_fixture(args.roc_bin, fixture, platform_manifest, out / "source", output)
        artifacts.append(output)
        results.append({"name": fixture.name, "source": fixture.source.as_posix(), "shape": fixture.shape})

    bridge_dir = out / "bridge"
    bridge_dir.mkdir()
    bridge_paths: list[Path] = []
    for name, data in sorted(runtime_files().items()):
        path = bridge_dir / name
        path.write_bytes(data)
        bridge_paths.append(path)
    compression = compressed_sizes(artifacts + bridge_paths)

    for entry, path in zip(results, artifacts):
        sections = wasm_sections(path.read_bytes())
        sizes = compression["files"][str(path)]
        entry.update({
            "raw": path.stat().st_size,
            "code": sections["code"],
            "data": sections.get("data", 0),
            "sections": sections,
            "gzip": sizes["gzip"],
            "brotli": sizes["brotli"],
            "sha256": sha256(path),
        })

    bridge_files = []
    for path in bridge_paths:
        sizes = compression["files"][str(path)]
        bridge_files.append({"name": path.name, "raw": path.stat().st_size, "gzip": sizes["gzip"], "brotli": sizes["brotli"], "sha256": sha256(path)})
    bridge = {
        "note": "browser runtime modules shipped alongside the Wasm; kept separate from the Wasm figures",
        "files": bridge_files,
        "raw": sum(file["raw"] for file in bridge_files),
        "gzip": sum(file["gzip"] for file in bridge_files),
        "brotli": sum(file["brotli"] for file in bridge_files),
    }
    for entry in results:
        entry["delivered"] = {metric: entry[metric] + bridge[metric] for metric in ("raw", "gzip", "brotli")}

    report = {
        "schema": 1,
        "label": args.label,
        "revision": revision,
        "dirty": dirty,
        "tools": {"roc": roc_version, "roc_pin": pin, "zig": zig_version, "node": node_version},
        "flags": {"host": HOST_BUILD[1:], "app": APP_FLAGS},
        "compression": {key: compression[key] for key in ("implementation", "gzip_level", "brotli_quality")},
        "host": {"raw": host_object.stat().st_size, "sha256": sha256(host_object), "stripped": True},
        "host_symbols": {"named_raw": named_host.stat().st_size, **symbol_inventory(named_host)} if named_host else None,
        "fixtures": results,
        "bridge": bridge,
    }
    report_path = out / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {report_path}", file=sys.stderr)
    return report


def format_int(value: int) -> str:
    return f"{value:,}"


def print_report(report: dict) -> None:
    print(f"revision {report['revision']}{' (dirty)' if report['dirty'] else ''}; {report['tools']['roc']}; zig {report['tools']['zig']}; compression {report['compression']['implementation']}")
    print()
    print("| Fixture | Raw | Code | Data | gzip 9 | Brotli 11 | Delivered gzip |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    totals = Counter()
    for entry in report["fixtures"]:
        for metric in ("raw", "code", "data", "gzip", "brotli"):
            totals[metric] += entry[metric]
        totals["delivered_gzip"] += entry["delivered"]["gzip"]
        print(
            f"| {entry['name']} | {format_int(entry['raw'])} | {format_int(entry['code'])} | {format_int(entry['data'])} "
            f"| {format_int(entry['gzip'])} | {format_int(entry['brotli'])} | {format_int(entry['delivered']['gzip'])} |"
        )
    print(
        f"| **cumulative** | {format_int(totals['raw'])} | {format_int(totals['code'])} | {format_int(totals['data'])} "
        f"| {format_int(totals['gzip'])} | {format_int(totals['brotli'])} | {format_int(totals['delivered_gzip'])} |"
    )
    bridge = report["bridge"]
    print()
    print(f"JS bridge: {format_int(bridge['raw'])} B raw, {format_int(bridge['gzip'])} B gzip, {format_int(bridge['brotli'])} B Brotli ({len(bridge['files'])} modules)")
    symbols = report.get("host_symbols")
    if symbols:
        print()
        print(f"Named host object (attribution only): {format_int(symbols['named_raw'])} B, {symbols['named_function_count']}/{symbols['function_count']} named functions")
        print()
        print("| Helper family (repeated) | Bodies | Bytes |")
        print("| --- | ---: | ---: |")
        for family in symbols["repeated_families"][:15]:
            print(f"| `{family['family']}` | {family['bodies']} | {format_int(family['bytes'])} |")
        print()
        print("| Largest host bodies | Bytes |")
        print("| --- | ---: |")
        for body in symbols["largest_bodies"]:
            print(f"| `{body['name']}` | {format_int(body['bytes'])} |")


def load_report(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def budget_for(value: int) -> int:
    return int(value * (1 + BUDGET_HEADROOM_PERCENT / 100))


def write_budgets(report: dict, path: Path = BUDGETS_PATH) -> None:
    lines = [
        "# Wasm size budgets checked by `python3 scripts/test.py size`.",
        "#",
        f"# Generated from a reproduced baseline with {BUDGET_HEADROOM_PERCENT:g}% headroom above the",
        "# measured value. Budgets are explicit numbers so a regression fails loudly.",
        "# Increasing a budget is a deliberate, reviewed decision: explain the cause",
        "# (compiler upgrade, accepted feature cost) in the pull request. Never",
        "# regenerate this file automatically to bless a larger artifact, and never",
        "# derive it from an instrumented or profiler build.",
        "#",
        "# Regenerate after an accepted change with:",
        "#   python3 scripts/wasm_size.py --write-budgets .test-out/size/<label>/report.json",
        "",
        "[baseline]",
        f'revision = "{report["revision"]}"',
        f'roc = "{report["tools"]["roc"]}"',
        f'zig = "{report["tools"]["zig"]}"',
        f'compression = "{report["compression"]["implementation"]}"',
        f"headroom_percent = {BUDGET_HEADROOM_PERCENT:g}",
        "",
    ]
    for entry in report["fixtures"]:
        lines.append(f"[fixtures.{entry['name']}]")
        for metric in GATED_METRICS:
            lines.append(f"{metric} = {budget_for(entry[metric])}  # measured {entry[metric]}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {path}", file=sys.stderr)


def check_budgets(report: dict, path: Path = BUDGETS_PATH) -> int:
    budgets = tomllib.loads(path.read_text(encoding="utf-8"))["fixtures"]
    failures: list[str] = []
    print()
    print("| Fixture | Metric | Measured | Budget | Margin |")
    print("| --- | --- | ---: | ---: | ---: |")
    for entry in report["fixtures"]:
        budget = budgets.get(entry["name"])
        if budget is None:
            failures.append(f"{entry['name']}: no budget in {path}")
            continue
        for metric in GATED_METRICS:
            limit = int(budget[metric])
            margin = limit - entry[metric]
            print(f"| {entry['name']} | {metric} | {format_int(entry[metric])} | {format_int(limit)} | {margin:+,} |")
            if margin < 0:
                failures.append(f"{entry['name']} {metric} {entry[metric]:,} exceeds budget {limit:,} by {-margin:,} bytes")
    missing = set(budgets) - {entry["name"] for entry in report["fixtures"]}
    if missing:
        failures.append("budgets without fixtures: " + ", ".join(sorted(missing)))
    print()
    if failures:
        for failure in failures:
            print(f"SIZE BUDGET FAILURE: {failure}")
        return 1
    print("all fixtures within size budgets")
    return 0


def compare(before: dict, after: dict) -> None:
    metrics = ("raw", "code", "gzip", "brotli")
    before_by_name = {entry["name"]: entry for entry in before["fixtures"]}
    after_by_name = {entry["name"]: entry for entry in after["fixtures"]}
    print(f"before: {before['label']} @ {before['revision'][:12]} ({before['tools']['roc']})")
    print(f"after:  {after['label']} @ {after['revision'][:12]} ({after['tools']['roc']})")
    if before["compression"] != after["compression"] or before["tools"]["zig"] != after["tools"]["zig"]:
        print("WARNING: compression or Zig version differs; deltas are not comparable")
    print()
    header = "| Fixture | " + " | ".join(f"{metric} before | {metric} after | delta" for metric in metrics) + " |"
    print(header)
    print("| --- | " + " | ".join("---: | ---: | ---:" for _ in metrics) + " |")
    totals = {metric: [0, 0] for metric in metrics}

    def cell(old: int, new: int) -> str:
        delta = new - old
        percent = (delta / old * 100) if old else 0.0
        return f"{format_int(old)} | {format_int(new)} | {delta:+,} ({percent:+.2f}%)"

    names = list(before_by_name) + [name for name in after_by_name if name not in before_by_name]
    for name in names:
        old, new = before_by_name.get(name), after_by_name.get(name)
        if old is None or new is None:
            print(f"| {name} | " + " | ".join("n/a | n/a | only in " + ("after" if old is None else "before") for _ in metrics) + " |")
            continue
        for metric in metrics:
            totals[metric][0] += old[metric]
            totals[metric][1] += new[metric]
        print(f"| {name} | " + " | ".join(cell(old[metric], new[metric]) for metric in metrics) + " |")
    print("| **cumulative** | " + " | ".join(cell(*totals[metric]) for metric in metrics) + " |")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--roc-bin", default=os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc")
    parser.add_argument("--label", default="baseline", help="Output directory name under .test-out/size/.")
    parser.add_argument("--symbols", action="store_true", help="Also build a named host companion for attribution.")
    parser.add_argument("--skip-host-build", action="store_true", help="Reuse platform-web/targets/wasm32/host.wasm as built.")
    parser.add_argument("--check", action="store_true", help="Fail when a fixture exceeds test/size/budgets.toml.")
    parser.add_argument("--write-budgets", metavar="REPORT", help="Regenerate budgets.toml from REPORT and exit.")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"), help="Compare two report.json files and exit.")
    parser.add_argument("--save", metavar="PATH", help="Also copy the report to PATH (e.g. test/size/baseline.json).")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.compare:
        compare(load_report(Path(args.compare[0])), load_report(Path(args.compare[1])))
        return 0
    if args.write_budgets:
        write_budgets(load_report(Path(args.write_budgets)))
        return 0
    report = measure(args)
    print_report(report)
    if args.save:
        Path(args.save).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"saved {args.save}", file=sys.stderr)
    if args.check:
        return check_budgets(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
