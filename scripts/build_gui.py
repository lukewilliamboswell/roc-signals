#!/usr/bin/env python3
"""Build the native GPUI platform's app-independent link inputs."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MACOS_FRAMEWORKS = ('AppKit', 'ApplicationServices', 'Carbon', 'CoreFoundation',
                    'CoreGraphics', 'CoreMedia', 'CoreText', 'CoreVideo',
                    'Foundation', 'IOKit', 'IOSurface', 'Metal', 'QuartzCore',
                    'ScreenCaptureKit', 'Security', 'SystemConfiguration')

def host_target():
    return {('Linux', 'x86_64'): 'x64glibc',
            ('Darwin', 'arm64'): 'arm64mac'}.get((platform.system(), platform.machine()))


def build_environment():
    """Select Xcode's installed Metal component while preserving explicit overrides."""
    environment = os.environ.copy()
    if platform.system() == 'Darwin':
        environment.setdefault('TOOLCHAINS', 'Metal')
    return environment


def copy_macos_sysroot(sdk, destination):
    """Retain SDK link stubs and their reexports, never SDK headers or binaries.

    Roc discovers frameworks in targets/macos-sysroot. Resolve SDK symlinks by
    copying their contents so an extracted package has no machine-local paths.
    """
    pending = [Path('System/Library/Frameworks') / (name + '.framework') / (name + '.tbd')
               for name in MACOS_FRAMEWORKS]
    pending += [Path('usr/lib') / name for name in ['libSystem.tbd', 'libobjc.tbd', 'libc++.tbd']]
    copied = set()
    while pending:
        relative = pending.pop()
        if relative in copied:
            continue
        source = sdk / relative
        content = source.read_text()
        if not re.search(r'^tbd-version:\s+4\s*$', content, re.MULTILINE):
            raise ValueError(f'Expected SDK TBD version 4: {source}')
        dest = destination / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
        copied.add(relative)
        # A TBD can contain multiple documents defining its own reexports.
        provided = set(re.findall(r"^install-name:\s*'([^']+)'", content, re.MULTILINE))
        for block in re.findall(r'^reexported-libraries:\n(.*?)(?=^\S|\Z)', content, re.MULTILINE | re.DOTALL):
            for name in re.findall(r"'(/[^']+)'", block):
                if name in provided:
                    continue
                path = Path(name.lstrip('/'))
                pending.append(path.with_suffix('.tbd') if path.suffix == '.dylib'
                               else Path(str(path) + '.tbd'))


def build(debug=False, jobs=2):
    target = host_target()
    if target is None:
        raise SystemExit('GUI builds require Linux x86_64 with glibc or Apple Silicon macOS.')
    if jobs < 1:
        raise SystemExit('GUI build jobs must be positive.')
    subprocess.run(['zig', 'build', 'build-gui-engine'], cwd=ROOT, check=True)
    # Worktrees may share dependencies, but Cargo can reuse the identically named
    # local crate from another checkout. Rebuild this small crate explicitly.
    subprocess.run(['cargo', 'clean', '-p', 'signals-gpui-host'], cwd=ROOT, check=True)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'signals-gpui-host', '-j', str(jobs)] + ([] if debug else ['--release']), cwd=ROOT, env=build_environment(), check=True)
    dest = ROOT / 'platform-gui/targets' / target
    dest.mkdir(parents=True, exist_ok=True)
    # Merge object members, not archives-as-members: Roc consumes one host archive.
    metadata = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--locked', '--no-deps', '--format-version=1'], cwd=ROOT, text=True,
    ))
    rust_host = Path(metadata['target_directory']) / ('debug' if debug else 'release') / 'libsignals_gpui_host.a'
    engine = ROOT / 'zig-out/gui/libengine.a'
    with tempfile.TemporaryDirectory(prefix='signals-host-') as tmp:
        stage = Path(tmp)
        shutil.copyfile(rust_host, stage / 'rust.a')
        shutil.copyfile(engine, stage / 'engine.a')
        if platform.system() == 'Darwin':
            subprocess.run(['libtool', '-static', '-o', 'libhost.a', 'rust.a', 'engine.a'], cwd=stage, check=True)
        else:
            subprocess.run(['ar', '-M'], input='CREATE libhost.a\nADDLIB rust.a\nADDLIB engine.a\nSAVE\nEND\n', text=True, cwd=stage, check=True)
        shutil.copyfile(stage / 'libhost.a', dest / 'libhost.a')
    for obsolete in ['libgpui_host.a', 'libengine.a']:
        (dest / obsolete).unlink(missing_ok=True)
    if platform.system() == 'Darwin':
        sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
        sysroot = dest.parent / 'macos-sysroot'
        with tempfile.TemporaryDirectory(prefix='signals-sdk-') as tmp:
            staged = Path(tmp) / 'macos-sysroot'
            copy_macos_sysroot(sdk, staged)
            if sysroot.exists():
                shutil.rmtree(sysroot)
            shutil.move(staged, sysroot)
        (dest / 'link-inputs.json').write_text(json.dumps({
            'sdk_version': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
            'sdk_build': subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True).strip(),
            'frameworks': MACOS_FRAMEWORKS,
        }, indent=2) + '\n')
        return
    for name in ['crt1.o', 'crti.o', 'crtn.o']:
        source = subprocess.check_output(['cc', '-print-file-name=' + name], text=True).strip()
        if not Path(source).is_file():
            raise SystemExit('Missing C runtime development input: ' + name)
        shutil.copyfile(source, dest / name)
    # Copy ELF inputs, not development linker scripts with machine-local paths.
    # Their SONAMEs retain runtime dependencies on the system's shared libraries.
    cache = subprocess.check_output(['/sbin/ldconfig', '-p'], text=True)
    provenance = {}
    for name in ['freetype', 'xkbcommon', 'xkbcommon-x11', 'gcc_s', 'util', 'rt', 'pthread', 'm', 'dl', 'c']:
        prefix = 'lib' + name + '.so.'
        matches = [line.split('=>')[1].strip() for line in cache.splitlines()
                   if line.strip().startswith(prefix) and 'x86-64' in line]
        if not matches:
            raise SystemExit('Missing system library: ' + prefix)
        source = Path(matches[0]).resolve()
        shutil.copyfile(source, dest / ('lib' + name + '.so'))
        provenance[name] = str(source)
    (dest / 'link-inputs.json').write_text(json.dumps(provenance, indent=2) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--debug', action='store_true', help='Use the faster development Rust build')
    parser.add_argument('--jobs', type=int, default=2, help='Concurrent Cargo build jobs (default: 2)')
    args = parser.parse_args()
    build(args.debug, args.jobs)
