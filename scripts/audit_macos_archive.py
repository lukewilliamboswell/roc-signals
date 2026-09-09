#!/usr/bin/env python3
"""Inventory external references in macOS host archives without reading an SDK.

This is a conservative union before archive extraction and dead stripping, not
the final executable's imports. Library ownership, weak-import attributes, and
interface provenance require separate review before generating linker stubs.
"""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess


def rust_llvm_nm():
    """Use the active Rust toolchain's reader so bundled bitcode is understood."""
    sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
    version = subprocess.check_output(['rustc', '-vV'], text=True)
    host = next(line.removeprefix('host: ') for line in version.splitlines() if line.startswith('host: '))
    tool = sysroot / 'lib/rustlib' / host / 'bin/llvm-nm'
    if not tool.is_file():
        raise ValueError('missing Rust LLVM reader; run rustup component add llvm-tools-preview')
    return tool


def parse_symbols(output, archive):
    """Preserve symbol spelling and referring members; reject unknown records."""
    pattern = re.compile(re.escape(str(archive)) + r'\[(.+)\]: (\S+) ([A-Za-z?]) ([0-9a-fA-F]+|-+) ([0-9a-fA-F]+)')
    references = defaultdict(set)
    definitions = set()
    kinds = defaultdict(int)
    for line in output.splitlines():
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError(f'unrecognized llvm-nm record: {line}')
        member, symbol, kind, _, _ = match.groups()
        kinds[kind] += 1
        if kind in ('U', 'w', 'v'):
            references[symbol].add(member)
        elif kind in ('A', 'B', 'C', 'D', 'G', 'I', 'R', 'S', 'T', 'V', 'W'):
            definitions.add(symbol)
        else:
            raise ValueError(f'unclassified llvm-nm symbol kind {kind}: {symbol}')
    return references, definitions, dict(sorted(kinds.items()))


def audit(archives, tool):
    """Subtract archive definitions while retaining an auditable import union.

    Every reader invocation must succeed. A partial scan from an incompatible
    LLVM version is refused, and archive hashes bind the result to exact bytes.
    """
    references = defaultdict(list)
    definitions = set()
    records = []
    version = subprocess.check_output([str(tool), '--version'], text=True).strip()
    for index, archive in enumerate(archives):
        before = hashlib.sha256(archive.read_bytes()).hexdigest()
        result = subprocess.run([
            str(tool), '--format=posix', '--print-file-name', '--extern-only',
            '--no-demangle', str(archive),
        ], capture_output=True, text=True, check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != before:
            raise ValueError(f'archive changed during inspection: {archive}')
        imported, provided, kinds = parse_symbols(result.stdout, archive)
        definitions.update(provided)
        for symbol, members in imported.items():
            references[symbol].extend({'archive': index, 'member': member} for member in sorted(members))
        records.append({'name': archive.name, 'sha256': before,
                        'symbol_records_by_kind': kinds,
                        'defined_symbol_count': len(provided),
                        'referenced_symbol_count': len(imported),
                        'reader_diagnostics': result.stderr.splitlines()})
    external = sorted(references.keys() - definitions)
    return {
        'schema_version': 1, 'reader_version': version, 'archives': records,
        'scope': 'All external archive references minus definitions in the supplied archives; before dead stripping.',
        'limitations': 'Includes engine/application callbacks. Does not establish library ownership, weak-import attributes, final reachability, or interface provenance.',
        'external_symbol_count': len(external),
        'external_symbols': [{'name': symbol, 'references': references[symbol]} for symbol in external],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archives', nargs='+', type=Path)
    parser.add_argument('--llvm-nm', type=Path, help='Override the active Rust toolchain reader')
    parser.add_argument('--output', type=Path, help='Write JSON here; defaults to stdout')
    args = parser.parse_args()
    archives = [path.resolve() for path in args.archives]
    if len(set(archives)) != len(archives):
        parser.error('duplicate archive inputs')
    result = audit(archives, args.llvm_nm or rust_llvm_nm())
    output = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end='')


if __name__ == '__main__':
    main()
