#!/usr/bin/env python3
"""Build the native GPUI platform's app-independent link inputs."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

from prepare_dependencies import install_freetype, install_glibc, install_xkbcommon, install_unwind

ROOT = Path(__file__).resolve().parent.parent

def host_target():
    return {('Linux', 'x86_64'): 'x64glibc',
            ('Darwin', 'arm64'): 'arm64mac',
            ('Windows', 'AMD64'): 'x64mingw'}.get((platform.system(), platform.machine()))


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


def build(debug=False, jobs=2, cargo_evidence=None):
    target = host_target()
    if target is None:
        raise SystemExit('GUI builds require Linux x86_64 with glibc, Apple Silicon macOS, or Windows x86_64.')
    if jobs < 1:
        raise SystemExit('GUI build jobs must be positive.')
    if debug and cargo_evidence is not None:
        raise SystemExit('Cargo release evidence requires an optimized build.')
    if target == 'x64mingw':
        build_windows(debug, jobs, cargo_evidence)
        return
    fingerprint = None
    if cargo_evidence is not None:
        from host_build_identity import source_fingerprint
        fingerprint = source_fingerprint(ROOT)
    linux_dependencies = (install_freetype(ROOT / 'platform-gui/targets/x64glibc')
                          if target == 'x64glibc' else None)
    if target == 'x64glibc':
        crt_dependencies = install_glibc(ROOT / 'platform-gui/targets/x64glibc')
        linux_dependencies['artifacts'].update(crt_dependencies['artifacts'])
        unwind_dependencies = install_unwind(ROOT / 'platform-gui/targets/x64glibc')
        linux_dependencies['artifacts'].update(unwind_dependencies['artifacts'])
        keyboard_dependencies = install_xkbcommon(ROOT / 'platform-gui/targets/x64glibc')
        linux_dependencies['artifacts'].update(keyboard_dependencies['artifacts'])
    subprocess.run(['zig', 'build', 'build-gui-engine'], cwd=ROOT, check=True)
    dest = ROOT / 'platform-gui/targets' / target
    dest.mkdir(parents=True, exist_ok=True)
    rust_name = 'libsignals_gpui_host.a'
    if cargo_evidence is not None:
        from cargo_build_evidence import capture
        rust_host = capture(ROOT, target, cargo_evidence, jobs, build_environment(), fingerprint)
    else:
        subprocess.run(['cargo', 'build', '--locked', '-p', 'signals-gpui-host', '-j', str(jobs)] + ([] if debug else ['--release']), cwd=ROOT, env=build_environment(), check=True)
        metadata = json.loads(subprocess.check_output(
            ['cargo', 'metadata', '--locked', '--no-deps', '--format-version=1'], cwd=ROOT, text=True,
        ))
        rust_host = Path(metadata['target_directory']) / ('debug' if debug else 'release') / rust_name
    engine = ROOT / 'zig-out/gui/libengine.a'
    # Roc's platform header lists both archives for its final application link.
    shutil.copyfile(rust_host, dest / rust_name)
    shutil.copyfile(engine, dest / 'libengine.a')
    (dest / host_archive(target)).unlink(missing_ok=True)
    if platform.system() == 'Darwin':
        finish_evidence(target, dest, cargo_evidence, fingerprint)
        return
    provenance = {'dependencies': linux_dependencies}
    (dest / 'link-inputs.json').write_text(json.dumps(provenance, indent=2) + '\n')
    finish_evidence(target, dest, cargo_evidence, fingerprint)


def build_windows(debug, jobs, cargo_evidence):
    """Build GNU host outputs and reuse independently verified Windows libraries."""
    from prepare_dependencies import install_windows_gnu, verified_windows_gnu, windows_gnu_inventory
    from windows_gnu_build import execute
    from windows_gnu_coff import normalize

    destination = ROOT / 'platform-gui/targets/x64mingw'
    dependencies = install_windows_gnu(destination)
    cargo_target = Path(os.environ.get('CARGO_TARGET_DIR', ROOT / 'target'))
    if not cargo_target.is_absolute():
        cargo_target = ROOT / cargo_target
    # Keep captured raw Cargo bytes separate from the final distributed archive.
    with tempfile.TemporaryDirectory(prefix='signals-windows-build-') as temporary, \
            tempfile.TemporaryDirectory(dir=destination, prefix='.host-') as staged_path:
        staged = Path(staged_path)
        output = cargo_evidence or Path(temporary) / 'build'
        payload = execute('build', output, jobs=jobs, cargo_target=cargo_target,
                          debug=debug, capture_evidence=cargo_evidence is not None)
        zig = output.resolve() / 'tools/zig-x86_64-windows-0.16.0/zig.exe'
        with verified_windows_gnu() as verified:
            inventory = windows_gnu_inventory(verified)
            receipt = normalize(payload / 'libsignals_gpui_host.a', staged / 'libsignals_gpui_host.a', inventory, zig)
        for name in ('libengine.a', 'signals.res'):
            shutil.copyfile(payload / name, staged / name)
        (staged / 'normalization.json').write_text(json.dumps(receipt, indent=2) + '\n')
        if cargo_evidence is not None:
            from host_notice_payload import validate_packaged_outputs
            evidence = json.loads((output / 'evidence.json').read_text())
            validate_packaged_outputs(json.loads((output / 'build.json').read_text()), 'x64mingw',
                                     evidence['source_fingerprint'], evidence['host'],
                                     {name: (staged / name).read_bytes() for name in
                                      ('libsignals_gpui_host.a', 'libengine.a', 'signals.res')}, receipt)
        (staged / 'link-inputs.json').write_text(json.dumps({
            'dependencies': dependencies,
            'rust_target': 'x86_64-pc-windows-gnullvm', 'engine_target': 'x86_64-windows-gnu',
            'manifest': 'crates/gpui-host/windows/signals.manifest.xml',
        }, indent=2) + '\n')

        for name in ('libsignals_gpui_host.a', 'libengine.a', 'signals.res', 'normalization.json', 'link-inputs.json'):
            (staged / name).replace(destination / name)


def finish_evidence(target, destination, evidence_root, fingerprint):
    """Seal every host-owned output after the complete native build succeeds."""
    if evidence_root is not None:
        from host_build_identity import record_outputs
        record_outputs(ROOT, target, destination, evidence_root, fingerprint)



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--debug', action='store_true', help='Use the faster development Rust build')
    parser.add_argument('--jobs', type=int, default=2, help='Concurrent Cargo build jobs (default: 2)')
    parser.add_argument('--cargo-evidence', type=Path, help='New directory for exact Cargo release evidence')
    args = parser.parse_args()
    build(args.debug, args.jobs, args.cargo_evidence)
