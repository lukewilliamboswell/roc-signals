#!/usr/bin/env python3
"""Publish tested complete Windows stubs under an independent immutable release."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from build_windows_system_imports import RECIPE, REPRODUCTION
from dependency_artifacts import read_lock, sha256, unpack_verified
from release_dependencies import REPOSITORY, publish_assets

KIND = 'windows-system-imports'


def prepare(directory, tag, environment):
    """Admit the exact candidate inventory and bind it to this main checkout."""
    if (environment.get('GITHUB_EVENT_NAME'), environment.get('GITHUB_REF'), environment.get('GITHUB_REPOSITORY')) != ('workflow_dispatch', 'refs/heads/main', REPOSITORY):
        raise ValueError('publication requires explicit main dispatch in producer repository')
    source = environment.get('GITHUB_SHA', '')
    if not re.fullmatch(r'[0-9a-f]{40}', source) or not re.fullmatch(r'deps-windows-system-imports-[0-9][A-Za-z0-9.-]*', tag):
        raise ValueError('invalid independent release identity')
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() != source:
        raise ValueError('publication checkout differs from tested source')
    archive = directory / (KIND + '-x64mingw.tar')
    if {p.name for p in directory.glob('*.tar')} != {archive.name}:
        raise ValueError('unexpected release archive inventory')
    recipe = json.loads(RECIPE.read_text())
    entry = {'name': KIND, 'target': 'x64mingw', 'repository': REPOSITORY, 'release': tag,
             'asset': archive.name, 'sha256': sha256(archive), 'size': archive.stat().st_size,
             'source_sha': source, 'source_ref': 'refs/heads/main',
             'signer_workflow': REPOSITORY + '/.github/workflows/windows-system-imports.yml'}
    with tempfile.TemporaryDirectory() as temporary:
        stage = Path(temporary) / "candidate"
        manifest = unpack_verified(archive, entry, stage)
        required = {'targets/x64mingw/' + dll.rsplit('.', 1)[0] + '.lib' for dll in recipe['dlls']}
        required.update('licenses/' + KIND + '/' + name for name in recipe['notices_sha256'])
        required.update('sources/' + KIND + '/' + name for name in (*REPRODUCTION, 'source.tar.xz', 'coverage.json'))
        if set(manifest['files']) != required or manifest['source'] != recipe:
            raise ValueError('candidate source or payload differs from reviewed producer inventory')
        for name, expected in recipe['notices_sha256'].items():
            if sha256(stage / 'licenses' / KIND / name) != expected:
                raise ValueError('candidate license differs from original source')
        for name in REPRODUCTION:
            if sha256(stage / 'sources' / KIND / name) != sha256(RECIPE.parents[1] / name):
                raise ValueError('candidate reproduction source differs from tested checkout')
    lock = directory / 'dependencies.lock.json'
    with lock.open('x') as output:
        json.dump({'schema_version': 1, 'artifacts': {KIND + '-x64mingw': entry}}, output, indent=2)
        output.write('\n')
    read_lock(lock)
    return source, [archive, lock]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    source, assets = prepare(args.directory, args.tag, os.environ)
    publish_assets(args.directory, args.tag, KIND, source, assets,
                   'Two fresh builds produced identical archives; an extracted candidate passed native ICUUC, NTDLL, OLE32 and KERNEL32 calls with OS-only DLL discovery.',
                   'These are complete reviewed source inventories of import stubs, not Windows implementation DLLs or a CRT package. No platform host or application code is included.')
