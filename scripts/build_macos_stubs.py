#!/usr/bin/env python3
"""Generate project-authored macOS linker interfaces from a reviewed symbol catalog.

Inputs are project source records and compiled host archives. No SDK headers,
TBDs, or framework binaries are read. The generated interfaces contain names
and linkage metadata only; macOS supplies the implementations at runtime.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'dependencies/macos-interfaces/interfaces.json'
PROVENANCE = ROOT / 'dependencies/macos-interfaces/PROVENANCE.md'
ARCHIVES = ('libsignals_gpui_host.a', 'libengine.a')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_catalog(path=CATALOG):
    return validate_catalog(json.loads(path.read_bytes()))


def validate_catalog(catalog):
    if catalog['schema_version'] != 1 or catalog['target'] != 'arm64-macos':
        raise ValueError('unsupported macOS interface catalog')
    seen_paths, seen_symbols = set(), set()
    for library in catalog['libraries']:
        name = library['path']
        relative = PurePosixPath(name)
        if (relative.is_absolute() or '..' in relative.parts or str(relative) != name
                or '\\' in name or relative.suffix != '.tbd' or name in seen_paths):
            raise ValueError('invalid or duplicate macOS interface path')
        seen_paths.add(name)
        if not re.fullmatch(r'/(?:usr/lib|System/Library/Frameworks)/[A-Za-z0-9_./+-]+', library['install_name']):
            raise ValueError('invalid macOS install name')
        if not library['path_sources']:
            raise ValueError('macOS library requires install-path evidence')
        for record in library['symbols']:
            symbol = record['name']
            if not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_$.]*', symbol) or symbol in seen_symbols:
                raise ValueError('invalid or duplicate macOS symbol')
            if not record['sources']:
                raise ValueError(f'macOS symbol requires source evidence: {symbol}')
            seen_symbols.add(symbol)
    if 'usr/lib/libSystem.tbd' not in seen_paths:
        raise ValueError('macOS interface catalog requires libSystem')
    return catalog


def render(catalog):
    """Emit deterministic TBD v4 YAML without SDK versions, UUIDs, or reexports."""
    files = {}
    for library in catalog['libraries']:
        lines = ['--- !tapi-tbd', 'tbd-version: 4', 'targets: [ arm64-macos ]',
                 "install-name: '" + library['install_name'] + "'"]
        symbols = sorted(record['name'] for record in library['symbols'])
        if symbols:
            lines += ['exports:', '  - targets: [ arm64-macos ]', '    symbols:']
            lines += ["      - '" + symbol + "'" for symbol in symbols]
        files[library['path']] = ('\n'.join(lines + ['...', ''])).encode()
    return files


def generate(archives, destination, catalog_path=CATALOG):
    """Bind generated interfaces to exact host inputs in a fresh output tree."""
    catalog_bytes = catalog_path.read_bytes()
    catalog = validate_catalog(json.loads(catalog_bytes))
    files = render(catalog)
    identities = {}
    for name in ARCHIVES:
        path = archives / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'missing or invalid macOS host archive: {path}')
        identities[name] = digest(path.read_bytes())
    provenance = PROVENANCE.read_bytes()
    manifest = {'schema_version': 1, 'origin': 'project-generated-macos-interfaces',
                'target': catalog['target'], 'host_archives_sha256': identities,
                'catalog_sha256': digest(catalog_bytes),
                'generator_sha256': digest(Path(__file__).read_bytes()),
                'provenance_sha256': digest(provenance),
                'files_sha256': {name: digest(data) for name, data in sorted(files.items())}}
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    destination.mkdir(parents=True)
    for name, data in files.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (destination / 'interfaces.json').write_bytes(catalog_bytes)
    (destination / 'PROVENANCE.md').write_bytes(provenance)
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def install(targets):
    """Replace local interface outputs only after complete generation succeeds."""
    with tempfile.TemporaryDirectory(prefix='.generated-macos-', dir=targets) as temporary:
        candidate = Path(temporary) / 'macos-sysroot'
        manifest = generate(targets / 'arm64mac', candidate)
        destination = targets / 'macos-sysroot'
        backup = Path(temporary) / 'previous'
        if destination.exists() or destination.is_symlink():
            destination.rename(backup)
        try:
            candidate.rename(destination)
        except OSError:
            if backup.exists() or backup.is_symlink():
                backup.rename(destination)
            raise
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archives', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = generate(args.archives.resolve(), args.output.resolve())
    print(json.dumps({'files': len(manifest['files_sha256']), 'origin': manifest['origin']}))
