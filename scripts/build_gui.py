#!/usr/bin/env python3
"""Build the native GPUI platform's app-independent link inputs."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from build_macos_stubs import install as install_macos_interfaces
from prepare_dependencies import install_windows_imports, install_freetype, install_xkbcommon

ROOT = Path(__file__).resolve().parent.parent

def host_target():
    return {('Linux', 'x86_64'): 'x64glibc',
            ('Darwin', 'arm64'): 'arm64mac',
            ('Windows', 'AMD64'): 'x64win'}.get((platform.system(), platform.machine()))


def host_archive(target):
    """Roc's Windows link lists COFF archives by their conventional name."""
    return 'host.lib' if target == 'x64win' else 'libhost.a'


def executable_name(name):
    return name + '.exe' if platform.system() == 'Windows' else name


def build_environment():
    """Select Xcode's installed Metal component while preserving explicit overrides."""
    environment = os.environ.copy()
    if platform.system() == 'Darwin':
        environment.setdefault('TOOLCHAINS', 'Metal')
    return environment


def build(debug=False, jobs=2):
    target = host_target()
    if target is None:
        raise SystemExit('GUI builds require Linux x86_64 with glibc, Apple Silicon macOS, or Windows x86_64.')
    if jobs < 1:
        raise SystemExit('GUI build jobs must be positive.')
    windows_dependencies = (install_windows_imports(ROOT / 'platform-gui/targets/x64win')
                            if target == 'x64win' else None)
    linux_dependencies = (install_freetype(ROOT / 'platform-gui/targets/x64glibc')
                          if target == 'x64glibc' else None)
    if target == 'x64glibc':
        keyboard_dependencies = install_xkbcommon(ROOT / 'platform-gui/targets/x64glibc')
        linux_dependencies['artifacts'].update(keyboard_dependencies['artifacts'])
    subprocess.run(['zig', 'build', 'build-gui-engine'], cwd=ROOT, check=True)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'signals-gpui-host', '-j', str(jobs)] + ([] if debug else ['--release']), cwd=ROOT, env=build_environment(), check=True)
    dest = ROOT / 'platform-gui/targets' / target
    dest.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--locked', '--no-deps', '--format-version=1'], cwd=ROOT, text=True,
    ))
    rust_name = 'signals_gpui_host.lib' if target == 'x64win' else 'libsignals_gpui_host.a'
    rust_host = Path(metadata['target_directory']) / ('debug' if debug else 'release') / rust_name
    engine = ROOT / 'zig-out/gui/libengine.a'
    # Roc's platform header lists both archives for its final application link.
    shutil.copyfile(rust_host, dest / rust_name)
    shutil.copyfile(engine, dest / ('engine.lib' if target == 'x64win' else 'libengine.a'))
    (dest / host_archive(target)).unlink(missing_ok=True)
    if target == 'x64win':
        build_windows_inputs(dest, windows_dependencies)
        return
    if platform.system() == 'Darwin':
        manifest = install_macos_interfaces(dest.parent)
        (dest / 'link-inputs.json').write_text(json.dumps({
            'macos_interfaces': manifest,
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
    provenance = {'dependencies': linux_dependencies}
    for name in ['gcc_s', 'util', 'rt', 'pthread', 'm', 'dl', 'c']:
        prefix = 'lib' + name + '.so.'
        matches = [line.split('=>')[1].strip() for line in cache.splitlines()
                   if line.strip().startswith(prefix) and 'x86-64' in line]
        if not matches:
            raise SystemExit('Missing system library: ' + prefix)
        source = Path(matches[0]).resolve()
        shutil.copyfile(source, dest / ('lib' + name + '.so'))
        provenance[name] = str(source)
    (dest / 'link-inputs.json').write_text(json.dumps(provenance, indent=2) + '\n')


def build_windows_inputs(dest, dependencies):
    """Produce the x64win inputs beyond the host archive itself.

    The application manifest is embedded into every executable Roc links: GPUI
    imports TaskDialogIndirect at load time, which only the Common Controls 6
    side-by-side comctl32 exports, and the manifest also declares per-monitor
    DPI awareness. External import libraries come from their verified release.
    """
    dest = dest.resolve()
    resources = ROOT / 'crates/gpui-host/windows'
    subprocess.run(['zig', 'rc', 'signals.rc', str(dest / 'signals.res')], cwd=resources, check=True)
    (dest / 'link-inputs.json').write_text(json.dumps({
        'manifest': 'crates/gpui-host/windows/signals.manifest.xml',
        'dependencies': dependencies,
        'rust_target': 'x86_64-pc-windows-msvc',
        'engine_target': 'x86_64-windows-msvc',
    }, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--debug', action='store_true', help='Use the faster development Rust build')
    parser.add_argument('--jobs', type=int, default=2, help='Concurrent Cargo build jobs (default: 2)')
    args = parser.parse_args()
    build(args.debug, args.jobs)
