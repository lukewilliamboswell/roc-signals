#!/usr/bin/env python3
"""Copy canonical shared modules into each platform's flat, gitignored module layout."""
import argparse
import hashlib
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent


def shared_modules(package: Path) -> dict[str, Path]:
    shared = package.parent / 'platform-shared'
    if not shared.is_dir():
        raise FileNotFoundError(shared)
    return {path.name: path for path in shared.glob('*.roc')}


def ignored_modules(package: Path) -> set[str]:
    return {line[1:] for line in (package / '.gitignore').read_text().splitlines()
            if line.startswith('/') and line.endswith('.roc')}


def prepare_platform(package: Path, destination: Path) -> None:
    sources = shared_modules(package)
    generated = ignored_modules(package)
    destination.mkdir(parents=True, exist_ok=True)
    if package.resolve() != destination.resolve():
        for path in package.glob('*.roc'):
            if path.name not in sources and path.name not in generated:
                shutil.copyfile(path, destination / path.name)
    for name, source in sources.items():
        shutil.copyfile(source, destination / name)


def check_platform(package: Path) -> list[str]:
    """Compare SHA-256 hashes without refreshing or repairing generated copies."""
    sources = shared_modules(package)
    ignored = ignored_modules(package)
    errors = []
    for name in sorted(ignored - sources.keys()):
        errors.append(f'{package.name}/{name}: no canonical source')
    for name, source in sorted(sources.items()):
        if name not in ignored:
            errors.append(f'{package.name}/{name}: generated module must be gitignored')
        copy = package / name
        if not copy.is_file():
            errors.append(f'{package.name}/{name}: missing shared copy')
        elif hashlib.sha256(copy.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
            errors.append(f'{package.name}/{name}: SHA-256 differs from platform-shared/{name}')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Reject missing or drifting copies without modifying files')
    args = parser.parse_args()
    errors = []
    for name in ['platform-web', 'platform-gui']:
        package = ROOT / name
        if not args.check:
            prepare_platform(package, package)
        errors.extend(check_platform(package))
    if errors:
        raise SystemExit('\n'.join(errors) + '\nEdit platform-shared, then run python3 scripts/prepare_platforms.py to refresh copies.')
    print('Shared platform copies match (SHA-256).')
