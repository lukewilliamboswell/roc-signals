#!/usr/bin/env python3
"""Validate a pure-import candidate and execute its OS-only native probe."""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from dependency_artifacts import unpack_verified
from windows_system_imports import imports

ROOT = Path(__file__).resolve().parents[1]


def check(archive, zig='zig', require_native=False):
    if require_native and platform.system() != 'Windows':
        raise ValueError('native Windows verification is required')
    expected = json.loads((ROOT / 'dependencies/windows-system-imports/inventory.json').read_text())
    with tempfile.TemporaryDirectory(prefix='signals-system-import-probe-') as temporary:
        work = Path(temporary)
        stage = work / 'candidate'
        manifest = unpack_verified(archive, {'name': 'windows-system-imports', 'target': 'x64mingw'}, stage)
        target = stage / 'targets/x64mingw'
        required = {dll.rsplit('.', 1)[0] + '.lib' for dll in expected}
        if {p.name for p in target.iterdir()} != required:
            raise ValueError('incomplete candidate DLL set')
        for dll, symbols in expected.items():
            if imports((target / (dll.rsplit('.', 1)[0] + '.lib')).read_bytes(), pure=True) != {dll: symbols}:
                raise ValueError('candidate differs from reviewed per-DLL inventory')
        executable = work / 'probe.exe'
        subprocess.run([zig, 'cc', '-target', 'x86_64-windows-gnu', '-O2', '-nostdlib',
                        '-Wl,--entry,mainCRTStartup',
                        str(ROOT / 'test/dependencies/windows_system_imports.c'),
                        *(str(target / (dll + '.lib')) for dll in ('icuuc', 'ntdll', 'ole32', 'kernel32')),
                        '-o', str(executable)], check=True)
        if platform.system() == 'Windows':
            system = Path(os.environ['SystemRoot'])
            environment = dict(os.environ, PATH=str(system / 'System32') + os.pathsep + str(system))
            subprocess.run([str(executable)], cwd=work, env=environment, check=True, timeout=30)
        else:
            print('Cross-link passed; native Windows execution remains unverified.')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--require-native', action='store_true')
    args = parser.parse_args()
    check(args.archive.resolve(), args.zig, args.require_native)
