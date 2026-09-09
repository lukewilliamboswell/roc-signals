#!/usr/bin/env python3
"""Publish tested complete Windows GNU runtime inputs under an independent immutable release."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from build_windows_gnu_runtime import RECIPE, REPRODUCTION
from dependency_artifacts import read_lock, sha256, unpack_verified, verify_archive
from release_dependencies import REPOSITORY, publish_assets

KIND = 'windows-gnu-runtime'


def prepare(directory, tag, environment):
    """Admit the exact candidate inventory and bind it to this main checkout."""
    if (environment.get('GITHUB_EVENT_NAME'), environment.get('GITHUB_REF'), environment.get('GITHUB_REPOSITORY')) != ('workflow_dispatch', 'refs/heads/main', REPOSITORY):
        raise ValueError('publication requires explicit main dispatch in producer repository')
    source = environment.get('GITHUB_SHA', '')
    if not re.fullmatch(r'[0-9a-f]{40}', source) or not re.fullmatch(r'deps-windows-gnu-runtime-[0-9][A-Za-z0-9.-]*', tag):
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
             'signer_workflow': REPOSITORY + '/.github/workflows/windows-gnu-runtime.yml'}
    verify_archive(archive, entry)
    with tempfile.TemporaryDirectory() as temporary:
        stage = Path(temporary) / "candidate"
        manifest = unpack_verified(archive, entry, stage)
        required = {'targets/x64mingw/' + name for name in recipe['files']}
        required.update('licenses/' + KIND + '/' + name for name in recipe['notices_sha256'])
        required.update('sources/' + KIND + '/' + name for name in (*REPRODUCTION, 'source.tar.xz'))
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
                   'Two fresh offline builds produced identical archives; native Windows tests exercised CRT startup and teardown, thread-local destructors, C++ and Rust unwinding, and mandatory UBSan failure.',
                   'The package contains full open-source CRT/runtime implementations and complete UCRT imports with weak aliases. Windows supplies the UCRT DLL implementations. No Microsoft SDK libraries or platform host code are included.')
