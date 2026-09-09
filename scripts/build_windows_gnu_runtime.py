#!/usr/bin/env python3
"""Build complete Windows GNU runtime inputs from a pinned Zig distribution."""

import argparse
import io
import json
import os
from pathlib import Path
import platform
import shutil
import shlex
import struct
import subprocess
import tarfile
import tempfile

from audit_windows_archive import members
from build_glibc import verified_toolchain, verified_header_search
from dependency_archive import digest, write_archive
from dependency_artifacts import sha256, unpack_verified
from windows_runtime_validation import ucrt_inventory

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'dependencies/windows-gnu-runtime.json'
BUILDER = ROOT / 'dependencies/windows-gnu-runtime/Dockerfile'
REPRODUCTION = (
    'dependencies/windows-gnu-runtime.json', 'dependencies/windows-gnu-runtime/Dockerfile',
    'dependencies/windows-gnu-runtime/DISCLAIMER.PD', 'dependencies/windows-gnu-runtime/ucrt-inventory.json',
    'scripts/build_windows_gnu_runtime.py', 'scripts/windows_runtime_validation.py',
    'scripts/audit_windows_archive.py', 'scripts/build_glibc.py', 'scripts/dependency_archive.py',
    'scripts/dependency_artifacts.py', 'scripts/test_windows_gnu_runtime_artifact.py',
    'test/dependencies/windows_gnu_runtime.cpp', 'test/dependencies/windows_gnu_runtime.rs',
    'test/dependencies/windows_gnu_ubsan.c',
    'test/dependencies/windows_gnu_compiler_rt.c',
)


def corresponding_source(distribution, recipe):
    """Preserve complete selected runtime sources and their original notices."""
    paths = {distribution / name for name in recipe['source_files']}
    for name in recipe['source_directories'] + recipe['headers']:
        paths.update(p for p in (distribution / name).rglob('*') if p.is_file())
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:xz', format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(paths):
            if path.is_symlink():
                raise ValueError('unexpected source link')
            data = path.read_bytes()
            entry = tarfile.TarInfo(path.relative_to(distribution).as_posix())
            entry.size = len(data)
            entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(data))
    return stream.getvalue()


def implementation_sections(data):
    """Compare code/data and resolved relocation targets across debug removal."""
    machine, count, _, symbols_offset, symbol_count, optional, _ = struct.unpack_from('<HHIIIHH', data)
    if machine != 0x8664 or optional != 0:
        raise ValueError('expected an AMD64 COFF implementation object')
    strings_offset = symbols_offset + symbol_count * 18

    def string(offset):
        start = strings_offset + offset
        return data[start:data.index(b'\0', start)]

    sections = [struct.unpack_from('<8sIIIIIIHHI', data, 20 + index * 40) for index in range(count)]
    names = [string(int(row[0].rstrip(b'\0')[1:])) if row[0].startswith(b'/') else row[0].rstrip(b'\0') for row in sections]

    def symbol(index, resolving=frozenset()):
        if index >= symbol_count or index in resolving:
            raise ValueError('invalid COFF relocation symbol')
        offset = symbols_offset + index * 18
        raw, value, section, kind, storage, auxiliaries = struct.unpack_from('<8sIhHBB', data, offset)
        name = string(struct.unpack_from('<I', raw, 4)[0]) if raw[:4] == bytes(4) else raw.rstrip(b'\0')
        target_section = names[section - 1] if section > 0 else section
        alias = None
        if storage == 105:
            if auxiliaries != 1:
                raise ValueError('unexpected weak external auxiliary record')
            target, policy = struct.unpack_from('<II', data, offset + 18)
            alias = (policy, symbol(target, resolving | {index}))
        return name, value, target_section, kind, storage, alias

    result = []
    for name, row in zip(names, sections):
        _, size_virtual, address, size, offset, relocations, _, relocation_count, _, flags = row
        if flags & 0x01000000:
            raise ValueError('unexpected extended relocation count')
        if not name.startswith(b'.debug'):
            references = []
            for index in range(relocation_count):
                address_relocation, target, kind = struct.unpack_from('<IIH', data, relocations + index * 10)
                references.append((address_relocation, kind, symbol(target)))
            result.append((name, size_virtual, address, size, flags,
                           data[offset:offset + size] if size and not flags & 0x80 else b'', tuple(references)))
    return result


def strip_runtime_debug(zig, source, destination, environment):
    """Use pinned LLVM objcopy for debug removal and Zig for deterministic indexing."""
    directory = destination.parent / (destination.name + '-objects')
    directory.mkdir()
    archive = source.suffix == '.lib'
    entries = [body for name, body in members(source.read_bytes()) if name not in ('/', '//')] if archive else [source.read_bytes()]
    outputs = []
    for index, body in enumerate(entries):
        original = directory / ('original-' + str(index) + '.obj')
        stripped = directory / (str(index).zfill(4) + '.obj')
        original.write_bytes(body)
        subprocess.run(['llvm-objcopy-19', '--strip-debug', str(original), str(stripped)], check=True)
        if implementation_sections(body) != implementation_sections(stripped.read_bytes()):
            raise ValueError('debug removal changed implementation sections')
        outputs.append(stripped)
    if archive:
        subprocess.run([zig, 'ar', 'rcsD', str(destination), *(p.name for p in outputs)],
                       cwd=directory, env=environment, check=True)
    else:
        shutil.copyfile(outputs[0], destination)


def inside(output, toolchain, image_id):
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    if sha256(toolchain) != recipe['toolchain']['sha256'] or toolchain.stat().st_size != recipe['toolchain']['size']:
        raise ValueError('unverified Zig toolchain')
    work = Path('/work')
    with tarfile.open(toolchain) as archive:
        archive.extractall(work / 'toolchain', filter='data')
    distribution = work / 'toolchain' / recipe['toolchain']['directory']
    zig = str(distribution / 'zig')
    if subprocess.check_output([zig, 'version'], text=True).strip() != recipe['zig_version']:
        raise ValueError('unexpected Zig version')
    environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR='/work/global', ZIG_LOCAL_CACHE_DIR='/work/local')
    for name in ('ZIG_LIB_DIR', 'ZIG_LIBC', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD'):
        environment.pop(name, None)
    verified_header_search([zig, 'cc', *recipe['cc_args']], distribution,
                          recipe['headers'], dict(environment, ZIG_GLOBAL_CACHE_DIR='/work/header-global', ZIG_LOCAL_CACHE_DIR='/work/header-local'), work)
    seed = work / 'seed.cpp'
    seed.write_text('#include <stdexcept>\nint main() { try { throw 42; } catch (int n) { return n == 42 ? 0 : 1; } }\n')
    bootstrap = subprocess.run([zig, 'c++', *recipe['cc_args'], str(seed), '-v', '-o', '/work/seed.exe'],
                               cwd=work, env=environment, capture_output=True, text=True, timeout=600)
    if bootstrap.returncode:
        print(bootstrap.stdout + bootstrap.stderr)
        bootstrap.check_returncode()
    links = [shlex.split(line) for line in (bootstrap.stdout + bootstrap.stderr).splitlines()
             if line.startswith('lld-link ') and '-OUT:/work/seed.exe' in line]
    if len(links) != 1:
        raise ValueError('expected one explicit Zig bootstrap final-link command')
    link_inputs = {}
    for argument in links[0]:
        path = (work / argument).resolve()
        if path.name in recipe['files']:
            if not path.is_relative_to(work / 'global/o') or not path.is_file() or path.name in link_inputs:
                raise ValueError('unexpected bootstrap runtime input: ' + argument)
            link_inputs[path.name] = path
    ubsan = work / 'ubsan_rt.lib'
    subprocess.run([zig, 'build-lib', str(distribution / 'lib/ubsan_rt.zig'),
                    '-target', 'x86_64-windows-gnu', '-mcpu=baseline', '-O', 'ReleaseSafe',
                    '-fno-compiler-rt', '-fstrip', '-femit-bin=' + str(ubsan)], cwd=work, env=dict(environment, ZIG_GLOBAL_CACHE_DIR='/work/ubsan-global', ZIG_LOCAL_CACHE_DIR='/work/ubsan-local'), check=True, timeout=600)
    # Zig's standalone build-lib uses a random temporary archive member path.
    # Re-index its one complete implementation object under a stable filename.
    objects = [(name, body) for name, body in members(ubsan.read_bytes()) if name not in ('/', '//')]
    if len(objects) != 1 or objects[0][1][:2] != b'\x64\x86':
        raise ValueError('expected one complete AMD64 UBSan implementation object')
    stable = work / 'ubsan_rt_zcu.obj'
    stable.write_bytes(objects[0][1])
    ubsan.unlink()
    subprocess.run([zig, 'ar', 'rcsD', str(ubsan), stable.name], cwd=work, env=environment, check=True)
    expected = json.loads((ROOT / 'dependencies/windows-gnu-runtime/ucrt-inventory.json').read_text())
    files = {}
    for name in recipe['files']:
        path = ubsan if name == 'ubsan_rt.lib' else link_inputs.get(name)
        if path is None:
            raise ValueError('bootstrap did not link the complete runtime input: ' + name)
        if name in ('crt2.obj', 'libmingw32.lib', 'unwind.lib'):
            normalized = work / ('normalized-' + name)
            strip_runtime_debug(zig, path, normalized, environment)
            path = normalized
        data = path.read_bytes()
        if name in expected and ucrt_inventory(data) != expected[name]:
            raise ValueError('UCRT source inventory or weak aliases changed: ' + name)
        files['targets/x64mingw/' + name] = data
    for name, source in recipe['notices'].items():
        files['licenses/windows-gnu-runtime/' + name] = (distribution / source).read_bytes()
    disclaimer = ROOT / 'dependencies/windows-gnu-runtime/DISCLAIMER.PD'
    if sha256(disclaimer) != recipe['disclaimer']['sha256']:
        raise ValueError('MinGW original disclaimer differs from its pin')
    files['licenses/windows-gnu-runtime/DISCLAIMER.PD'] = disclaimer.read_bytes()
    if {name: digest(files['licenses/windows-gnu-runtime/' + name]) for name in recipe['notices_sha256']} != recipe['notices_sha256']:
        raise ValueError('original runtime notices differ from their reviewed pins')
    files['sources/windows-gnu-runtime/source.tar.xz'] = corresponding_source(distribution, recipe)
    for name in REPRODUCTION:
        files['sources/windows-gnu-runtime/' + name] = (ROOT / name).read_bytes()
    archive = write_archive(output / 'windows-gnu-runtime-x64mingw.tar', {
        'schema_version': 1, 'name': recipe['name'], 'version': recipe['version'], 'target': recipe['target'],
        'source': recipe, 'build': {'builder_image': image_id, 'builder_sha256': sha256(BUILDER),
                                  'recipe_sha256': digest(recipe_bytes),
                                  'reproduction_sha256': {name: sha256(ROOT / name) for name in REPRODUCTION}}}, files)
    # The Windows job executes an independently extracted candidate before attestation.
    unpack_verified(archive, {'name': recipe['name'], 'target': recipe['target']}, work / 'candidate')
    print(sha256(archive), archive)
    return archive


def build(output, cache):
    if (platform.system(), platform.machine()) != ('Linux', 'x86_64'):
        raise ValueError('runtime producer requires Linux x86-64 and Docker')
    recipe = json.loads(RECIPE.read_text())
    toolchain = verified_toolchain(recipe['toolchain'], cache)
    destination = output / 'windows-gnu-runtime-x64mingw.tar'
    if destination.exists():
        raise FileExistsError(destination)
    tag = 'signals-windows-gnu-runtime:' + sha256(BUILDER)[:24]
    subprocess.run(['docker', 'build', '--platform=linux/amd64', '--tag', tag, str(BUILDER.parent)], check=True, timeout=1800)
    image_id = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', tag], text=True).strip()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix='.runtime-') as temporary:
        stage = Path(temporary)
        subprocess.run([
            'docker', 'run', '--platform=linux/amd64', '--rm', '--network=none', '--read-only',
            '--cap-drop=ALL', '--security-opt=no-new-privileges', '--user', f'{os.getuid()}:{os.getgid()}',
            '--tmpfs', '/work:exec,mode=1777', '--tmpfs', '/tmp:exec,mode=1777',
            '--env', 'PYTHONDONTWRITEBYTECODE=1', '--workdir', '/work',
            '--volume', str(ROOT / 'scripts') + ':/repo/scripts:ro',
            '--volume', str(ROOT / 'dependencies') + ':/repo/dependencies:ro',
            '--volume', str(ROOT / 'test/dependencies') + ':/repo/test/dependencies:ro',
            '--volume', str(toolchain) + ':/source.tar.xz:ro', '--volume', str(stage) + ':/output',
            image_id, 'python3', '/repo/scripts/build_windows_gnu_runtime.py', '--inside', '--image-id', image_id,
            '--output', '/output'], check=True, timeout=1200)
        os.link(stage / destination.name, destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/roc-signals/sources')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--image-id', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        inside(args.output, Path('/source.tar.xz'), args.image_id)
    else:
        print(build(args.output.resolve(), args.cache.resolve()))
