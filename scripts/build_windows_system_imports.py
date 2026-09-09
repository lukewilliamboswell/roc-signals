#!/usr/bin/env python3
"""Build complete source-derived Windows import stubs without host or SDK inputs."""

import argparse
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

from build_glibc import verified_toolchain
from dependency_archive import digest, write_archive
from windows_system_imports import imports, merge, source_coverage

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'dependencies/windows-system-imports.json'
SOURCE = ROOT / 'dependencies/windows-system-imports'
REPRODUCTION = (
    'dependencies/windows-system-imports.json',
    'dependencies/windows-system-imports/Cargo.toml',
    'dependencies/windows-system-imports/Cargo.lock',
    'dependencies/windows-system-imports/src/lib.rs',
    'dependencies/windows-system-imports/inventory.json',
    'scripts/build_windows_system_imports.py', 'scripts/windows_system_imports.py',
    'scripts/audit_windows_archive.py', 'scripts/build_glibc.py',
    'scripts/dependency_archive.py', 'scripts/dependency_artifacts.py',
    'scripts/test_windows_system_import_artifact.py',
    'test/dependencies/windows_system_imports.c',
)


def unpack(archive, destination):
    """Extract verified upstream sources and installers with Python's data filter."""
    with tarfile.open(archive) as packed:
        packed.extractall(destination, filter='data')


def setup_tools(recipe, archives, work):
    """Install exact checksum-pinned Rust components and Zig in private directories."""
    unpack(archives['zig'], work / 'zig')
    zig = work / 'zig' / recipe['zig']['directory'] / 'zig'
    rust = work / 'rust'
    for number, component in enumerate(recipe['rust_components']):
        stage = work / f'installer-{number}'
        unpack(archives['rust'][number], stage)
        installers = list(stage.glob('*/install.sh'))
        if len(installers) != 1:
            raise ValueError('unexpected Rust installer inventory')
        subprocess.run(['sh', str(installers[0]), '--prefix=' + str(rust), '--disable-ldconfig'], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(stage)
    if subprocess.check_output([str(zig), 'version'], text=True).strip() != '0.16.0':
        raise ValueError('unexpected pinned Zig version')
    if not subprocess.check_output([str(rust / 'bin/rustc'), '--version'], text=True).startswith('rustc ' + recipe['rust_version'] + ' '):
        raise ValueError('unexpected pinned Rust version')
    return zig, rust


def source_archive(files):
    """Retain original source/notice bytes with reproducible archive metadata."""
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:xz', format=tarfile.PAX_FORMAT) as packed:
        for name, data in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            packed.addfile(entry, io.BytesIO(data))
    return result.getvalue()


def build(output, cache):
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    expected = json.loads((SOURCE / 'inventory.json').read_text())
    if set(expected) != set(recipe['dlls']):
        raise ValueError('recipe DLLs differ from reviewed inventory')
    lock = tomllib.loads((SOURCE / 'Cargo.lock').read_text())
    locked = {(p['name'], p['version']): p['checksum'] for p in lock['package'] if 'checksum' in p}
    if locked != {(p['name'], p['version']): p['sha256'] for p in recipe['crates']}:
        raise ValueError('crate downloads differ from Cargo.lock')
    archives = {'zig': verified_toolchain(recipe['zig'], cache),
                'rust': [verified_toolchain(p, cache) for p in recipe['rust_components']],
                'crates': [verified_toolchain(p, cache) for p in recipe['crates']]}
    with tempfile.TemporaryDirectory(prefix='signals-system-imports-') as temporary:
        work = Path(temporary)
        zig, rust = setup_tools(recipe, archives, work)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('RUST', 'CARGO_', 'ZIG_'))}
        environment.update(PATH=str(rust / 'bin') + os.pathsep + '/usr/bin:/bin',
                           CARGO_HOME=str(work / 'cargo-home'), CARGO_TARGET_DIR=str(work / 'target'),
                           CARGO_INCREMENTAL='0', RUSTC=str(rust / 'bin/rustc'),
                           ZIG_GLOBAL_CACHE_DIR=str(work / 'zig-global'), ZIG_LOCAL_CACHE_DIR=str(work / 'zig-local'))
        package = work / 'bindings'
        shutil.copytree(SOURCE, package)
        vendor = work / 'vendor'
        source_files, notices = {}, {}
        for pin, archive in zip(recipe['crates'], archives['crates'], strict=True):
            unpack(archive, vendor)
            directory = vendor / (pin['name'] + '-' + pin['version'])
            original = {p.relative_to(directory).as_posix(): p.read_bytes() for p in directory.rglob('*') if p.is_file()}
            (directory / '.cargo-checksum.json').write_text(json.dumps({'package': pin['sha256'], 'files': {n: digest(b) for n, b in original.items()}}))
            source_files['crates/' + directory.name + '.crate'] = archive.read_bytes()
            for name, data in original.items():
                if Path(name).name.lower().startswith(('license', 'copying', 'notice')):
                    notices[directory.name + '/' + name] = data
        manifest = tomllib.loads((package / 'Cargo.toml').read_text())
        sys_features = tomllib.loads((vendor / 'windows-sys-0.61.2/Cargo.toml').read_text())['features']
        if set(manifest['dependencies']['windows-sys']['features']) != set(sys_features):
            raise ValueError('windows-sys requires its complete upstream feature inventory')
        config = package / '.cargo/config.toml'
        config.parent.mkdir()
        config.write_text('[source.crates-io]\nreplace-with="vendored"\n[source.vendored]\ndirectory=' + json.dumps(str(vendor)) + '\n')
        subprocess.run([str(rust / 'bin/cargo'), 'build', '--offline', '--locked', '--target', recipe['rust_target'], '-j2'], cwd=package, env=environment, check=True)
        inventory = {}
        for crate in ('windows_sys', 'windows'):
            libraries = list((work / 'target' / recipe['rust_target'] / 'debug/deps').glob('lib' + crate + '-*.rlib'))
            if len(libraries) != 1:
                raise ValueError('ambiguous compiler output')
            component = imports(libraries[0].read_bytes())
            merge(inventory, {dll: symbols for dll, symbols in component.items() if dll in expected})
        coverage = source_coverage(vendor / 'windows-0.61.3/src', expected)
        zig_source = zig.parent
        bootstrap = work / 'bootstrap.c'
        bootstrap.write_text('int main(void) { return 0; }\n')
        subprocess.run([str(zig), 'cc', '-target', 'x86_64-windows-gnu', '-mcpu=baseline', str(bootstrap), *('-l' + n for n in recipe['zig_libraries']), '-o', str(work / 'bootstrap.exe')], env=environment, check=True)
        for name in recipe['zig_libraries']:
            libraries = list((work / 'zig-global').rglob(name + '.lib'))
            if len(libraries) != 1:
                raise ValueError('ambiguous Zig full import output: ' + name)
            merge(inventory, imports(libraries[0].read_bytes(), pure=True))
        if inventory != expected:
            missing = [(d, s) for d, ss in expected.items() for s in ss if inventory.get(d, {}).get(s) != ss[s]]
            extra = [(d, s) for d, ss in inventory.items() for s in ss if expected.get(d, {}).get(s) != ss[s]]
            raise ValueError(f'compiler inventory differs from reviewed complete definitions: missing={missing[:10]}, extra={extra[:10]}')
        files = {}
        for dll, symbols in sorted(inventory.items()):
            name = dll.rsplit('.', 1)[0]
            definition, library = work / (name + '.def'), work / (name + '.lib')
            definition.write_text('LIBRARY "' + dll + '"\nEXPORTS\n' + '\n'.join(s + (' DATA' if f == 5 else '') for s, f in sorted(symbols.items())) + '\n')
            subprocess.run([str(zig), 'dlltool', '-m', 'i386:x86-64', '-d', str(definition), '-l', str(library)], check=True)
            data = library.read_bytes()
            if imports(data, pure=True) != {dll: symbols}:
                raise ValueError('generated archive differs from full inventory')
            files['targets/x64mingw/' + library.name] = data
        mingw = zig_source / 'lib/libc/mingw'
        # Retain only original definition inputs; no CRT implementation is packaged.
        for name, expected_hash in recipe['zig_definition_files_sha256'].items():
            data = (mingw / name).read_bytes()
            if digest(data) != expected_hash:
                raise ValueError('Zig definition input differs from its reviewed pin: ' + name)
            source_files['zig/mingw/' + name] = data
        notices['COPYING-MINGW'] = (mingw / 'COPYING').read_bytes()
        notices['LICENSE-ZIG'] = (zig_source / 'LICENSE').read_bytes()
        notices['LICENSE-LLVM'] = (zig_source / 'lib/libunwind/LICENSE.TXT').read_bytes()
        source_files['zig/mingw/COPYING'] = notices['COPYING-MINGW']
        if {name: digest(data) for name, data in notices.items()} != recipe['notices_sha256']:
            raise ValueError('original notice inventory differs from reviewed pins')
        files.update({'licenses/windows-system-imports/' + n: b for n, b in notices.items()})
        prefix = 'sources/windows-system-imports/'
        files[prefix + 'source.tar.xz'] = source_archive(source_files)
        files[prefix + 'coverage.json'] = (json.dumps(coverage, indent=2) + '\n').encode()
        for name in REPRODUCTION:
            files[prefix + name] = (ROOT / name).read_bytes()
        metadata = {'schema_version': 1, 'name': recipe['name'], 'version': recipe['version'], 'target': recipe['target'],
                    'source': recipe, 'build': {'recipe_sha256': digest(recipe_bytes),
                    'reproduction_sha256': {name: digest((ROOT / name).read_bytes()) for name in REPRODUCTION},
                    'dll_count': len(inventory), 'symbol_count': sum(map(len, inventory.values()))}}
        archive = write_archive(output / 'windows-system-imports-x64mingw.tar', metadata, files)
    print(digest(archive.read_bytes()), archive)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', required=True, type=Path)
    args = parser.parse_args()
    build(args.output.resolve(), args.cache.resolve())
