#!/usr/bin/env python3
"""Package pinned Apple linker interfaces without compiling the GUI host.

The recipe records the reviewed SDK bytes and reexport graph. Only those exact
bytes are admitted; metadata is not inferred from a consumer's local SDK.
"""

import argparse
import json
from pathlib import Path, PurePosixPath

import dependency_archive
from dependency_archive import digest, write_archive

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'dependencies/macos-stubs.json'
NOTICE = ROOT / 'dependencies/macos-stubs/NOTICE'
IDENTITY = 'macos-stubs-macos-sysroot'


def read_recipe(path=RECIPE):
    recipe = json.loads(path.read_bytes())
    if (recipe['schema_version'] != 1 or recipe['name'] != 'macos-stubs'
            or recipe['target'] != 'macos-sysroot' or not recipe['files']):
        raise ValueError('invalid macOS stub recipe')
    for name, record in recipe['files'].items():
        relative = PurePosixPath(name)
        if (relative.is_absolute() or '..' in relative.parts or str(relative) != name
                or '\\' in name or relative.suffix != '.tbd'):
            raise ValueError('invalid macOS stub path')
        if not record['install_names']:
            raise ValueError('stub must declare its install names')
        for install_name in record['reexports']:
            if install_name in record['install_names']:
                continue
            target = PurePosixPath(install_name.removeprefix('/'))
            target = (target.with_suffix('.tbd') if target.suffix == '.dylib'
                      else PurePosixPath(str(target) + '.tbd'))
            provider = recipe['files'].get(str(target))
            if provider is None or install_name not in provider['install_names']:
                raise ValueError(f'unresolved macOS reexport from {name}: {install_name}')
    return recipe


def expected_files(recipe):
    return ({'targets/macos-sysroot/' + name for name in recipe['files']}
            | {'licenses/macos-stubs/Xcode-and-Apple-SDKs-Agreement.rtf',
               'licenses/macos-stubs/NOTICE', 'sources/macos-stubs/recipe.json'})


def validate_contents(root, recipe):
    """Check exact selected SDK bytes and notices after archive verification."""
    for name, record in recipe['files'].items():
        path = root / 'targets/macos-sysroot' / name
        if path.is_symlink() or digest(path.read_bytes()) != record['sha256']:
            raise ValueError(f'macOS stub differs from reviewed pin: {name}')
    license_path = root / 'licenses/macos-stubs/Xcode-and-Apple-SDKs-Agreement.rtf'
    if digest(license_path.read_bytes()) != recipe['license_sha256']:
        raise ValueError('Xcode agreement differs from reviewed pin')
    if (root / 'licenses/macos-stubs/NOTICE').read_bytes() != NOTICE.read_bytes():
        raise ValueError('macOS provenance notice differs from reviewed selection')
    if json.loads((root / 'sources/macos-stubs/recipe.json').read_bytes()) != recipe:
        raise ValueError('macOS archive recipe differs from reviewed selection')


def build(sdk, license_path, output, recipe_path=RECIPE):
    recipe = read_recipe(recipe_path)
    files = {}
    # Read and verify every input before the archive writer creates output.
    for name, record in recipe['files'].items():
        source = sdk / name
        if not source.resolve().is_relative_to(sdk.resolve()):
            raise ValueError(f'macOS SDK symlink escapes SDK: {name}')
        data = source.read_bytes()
        if digest(data) != record['sha256']:
            raise ValueError(f'macOS stub differs from reviewed pin: {name}')
        files['targets/macos-sysroot/' + name] = data
    license_data = license_path.read_bytes()
    if digest(license_data) != recipe['license_sha256']:
        raise ValueError('Xcode agreement differs from reviewed pin')
    files['licenses/macos-stubs/Xcode-and-Apple-SDKs-Agreement.rtf'] = license_data
    files['licenses/macos-stubs/NOTICE'] = NOTICE.read_bytes()
    files['sources/macos-stubs/recipe.json'] = recipe_path.read_bytes()
    metadata = {
        'schema_version': 1, 'name': recipe['name'], 'version': recipe['version'],
        'target': recipe['target'],
        'source': {key: recipe[key] for key in ('xcode_version', 'xcode_build',
                                               'sdk_version', 'sdk_build')},
        'build': {'recipe_sha256': digest(recipe_path.read_bytes()),
                  'producer_sha256': digest(Path(__file__).read_bytes()),
                  'archive_writer_sha256': digest(Path(dependency_archive.__file__).read_bytes())},
    }
    result = write_archive(output / (IDENTITY + '.tar'), metadata, files)
    print(f'{digest(result.read_bytes())}  {result}')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--xcode-license', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.sdk.resolve(), args.xcode_license.resolve(), args.output.resolve())
