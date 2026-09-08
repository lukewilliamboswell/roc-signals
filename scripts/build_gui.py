#!/usr/bin/env python3
"""Build the Linux x64 GPUI platform's app-independent link inputs."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def build(debug=False, jobs=2):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise SystemExit('The GUI spike currently supports Linux x86_64 with glibc only.')
    if jobs < 1:
        raise SystemExit('GUI build jobs must be positive.')
    subprocess.run(['zig', 'build', 'build-gui-engine'], cwd=ROOT, check=True)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'signals-gpui-host', '-j', str(jobs)] + ([] if debug else ['--release']), cwd=ROOT, check=True)
    dest = ROOT / 'platform-gui/targets/x64glibc'
    dest.mkdir(parents=True, exist_ok=True)
    # Merge object members, not archives-as-members: Roc consumes one host archive.
    rust_host = ROOT / 'target' / ('debug' if debug else 'release') / 'libsignals_gpui_host.a'
    engine = ROOT / 'zig-out/gui/libengine.a'
    with tempfile.TemporaryDirectory(prefix='signals-host-') as tmp:
        stage = Path(tmp)
        shutil.copyfile(rust_host, stage / 'rust.a')
        shutil.copyfile(engine, stage / 'engine.a')
        subprocess.run(['ar', '-M'], input='CREATE libhost.a\nADDLIB rust.a\nADDLIB engine.a\nSAVE\nEND\n', text=True, cwd=stage, check=True)
        shutil.copyfile(stage / 'libhost.a', dest / 'libhost.a')
    for obsolete in ['libgpui_host.a', 'libengine.a']:
        (dest / obsolete).unlink(missing_ok=True)
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
