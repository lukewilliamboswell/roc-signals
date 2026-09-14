#!/usr/bin/env python3
"""Build paired no-render Rows workloads and check fixed-edit allocation scaling."""
import argparse
from pathlib import Path
import subprocess

import test as driver
from instrument_wasm import instrument_wasm
from prepare_platforms import prepare_platform

ROOT = Path(__file__).resolve().parents[1]


def flat_directory_mutation(source: str) -> str:
    """Restore flat COW storage while preserving the directory's semantics."""
    start = source.index('RowsSlotDirectory(value) :')
    end = source.index('RowsGenerationCallable :', start)
    return source[:start] + """RowsSlotDirectory(value) : { entries : Dict(U64, value) }
rows_slot_directory_empty : () -> RowsSlotDirectory(value)
rows_slot_directory_empty = || { entries: Dict.empty() }
rows_slot_directory_len : RowsSlotDirectory(value) -> U64
rows_slot_directory_len = |directory| directory.entries.len()
rows_slot_directory_is_empty : RowsSlotDirectory(value) -> Bool
rows_slot_directory_is_empty = |directory| directory.entries.is_empty()
rows_slot_directory_get : RowsSlotDirectory(value), U64 -> Try(value, [Missing])
rows_slot_directory_get = |directory, key| Ok(directory.entries.get(key) ? |_| Missing)
rows_slot_directory_insert : RowsSlotDirectory(value), U64, value -> RowsSlotDirectory(value)
rows_slot_directory_insert = |directory, key, value| { entries: directory.entries.insert(key, value) }

""" + source[end:]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--roc-bin', default='roc')
    parser.add_argument('--skip-host-build', action='store_true')
    parser.add_argument('--build-only', action='store_true', help='Build artifacts without starting measurements.')
    parser.add_argument('--output-dir', type=Path, default=ROOT / '.test-out/rows-scaling')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--rows-source', type=Path, help='Use a baseline Rows module for an isolated comparison.')
    parser.add_argument('--flat-directory-mutation', action='store_true', help='Deliberately restore flat storage; the allocation gate must fail.')
    parser.add_argument('--no-check', action='store_true', help='Report a baseline without accepting its allocation scaling.')
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('--samples must be positive')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    prepare_platform(ROOT / 'platform-web', ROOT / 'platform-web')
    if not args.skip_host_build:
        driver.benchmark_run(['zig', 'build', 'build-wasm-benchmark-host', '-Doptimize=ReleaseFast'])
    original = (ROOT / 'test/rows-scaling/main.roc').read_text()
    for kind, instrumented, host in [('production', False, 'production-host.o'), ('diagnostic', True, 'host.o')]:
        platform = output / f'{kind}-platform'
        driver.prepare_wasm_benchmark_platform(platform, ROOT / 'zig-out/wasm-benchmark' / host, instrumented=instrumented)
        rows_source = args.rows_source.read_text() if args.rows_source else (ROOT / 'platform-shared/Rows.roc').read_text()
        if args.flat_directory_mutation:
            rows_source = flat_directory_mutation(rows_source)
        (platform / 'Rows.roc').write_text(rows_source)
        source = output / f'{kind}.roc'
        source.write_text(driver.PLATFORM_HEADER_RE.sub(f'platform "{platform / "main.roc"}"', original, count=1))
        wasm = output / f'{kind}.wasm'
        driver.benchmark_run([args.roc_bin, 'build', '--target=wasm32', '--opt=speed', '--no-cache', f'--output={wasm}', source])
        instrument_wasm(wasm)
    if args.build_only:
        return
    command = ['node', '--no-maglev', ROOT / 'scripts/browser/run_rows_scaling.mjs', output / 'production.wasm', output / 'diagnostic.wasm', '--samples', str(args.samples)]
    if args.flat_directory_mutation:
        command.append('--directory-only')
    if args.no_check:
        command.append('--no-check')
    subprocess.run([str(part) for part in command], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
