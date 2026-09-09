#!/usr/bin/env python3
"""Link and execute a probe against the exact unsigned producer candidate.

This test precedes signing. Release consumers must use attestation verification
instead of treating successful execution as evidence of provenance.
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from build_macos_stubs import read_recipe, expected_files, validate_contents
from dependency_artifacts import unpack_verified

ROOT = Path(__file__).resolve().parents[1]


def check(archive):
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('macOS dependency execution requires Apple Silicon macOS')
    recipe = read_recipe()
    with tempfile.TemporaryDirectory(prefix='signals-macos-probe-') as temporary:
        work = Path(temporary)
        inputs = work / 'inputs'
        manifest = unpack_verified(archive, recipe, inputs)
        if set(manifest['files']) != expected_files(recipe):
            raise ValueError('unexpected macOS interface inventory')
        validate_contents(inputs, recipe)
        sdk = inputs / 'targets/macos-sysroot'
        flags = []
        for name in recipe['files']:
            path = Path(name)
            if (path.parent.parent.as_posix() == 'System/Library/Frameworks'
                    and path.parent.name == path.stem + '.framework'):
                flags.extend(['-framework', path.stem])
        linker = subprocess.check_output(['xcrun', '--find', 'ld'], text=True).strip()
        environment = os.environ.copy()
        environment.update(SDKROOT=str(sdk), DEVELOPER_DIR='/nonexistent')
        executable = work / 'probe'
        object_file = work / 'probe.o'
        subprocess.run([
            'zig', 'cc', '-target', 'aarch64-macos', '-c', '-fno-sanitize=all',
            str(ROOT / 'test/dependencies/macos_stubs.c'), '-o', str(object_file),
        ], env=environment, check=True)
        subprocess.run([
            linker, '-arch', 'arm64', '-platform_version', 'macos', '13.0', '26.2',
            '-syslibroot', str(sdk), '-L' + str(sdk / 'usr/lib'),
            '-F' + str(sdk / 'System/Library/Frameworks'),
            str(object_file), *flags, '-lSystem', '-lobjc', '-lc++',
            '-o', str(executable),
        ], env=environment, check=True)
        subprocess.run([str(executable)], check=True, timeout=15)
        subprocess.run(['otool', '-L', str(executable)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    check(parser.parse_args().archive.resolve())
