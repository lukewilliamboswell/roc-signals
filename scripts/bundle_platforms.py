#!/usr/bin/env python3
"""Build, bundle, and optionally serve the web and GUI Roc platforms."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from build_gui import build as build_gui
from prepare_platforms import prepare_platform

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', choices=['all', 'web', 'gui'], default='all')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--debug-gui', action='store_true')
    parser.add_argument('--output-dir', type=Path, default=Path(os.environ.get('BUNDLE_OUT_DIR', str(ROOT / '.test-out/bundles'))))
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    packages = ['web', 'gui'] if args.package == 'all' else [args.package]
    roc = os.environ.get('ROC_BIN', os.environ.get('ROC', 'roc'))
    # Resolve before running from the staging directory; callers may pass a relative path.
    roc = str(Path(shutil.which(roc) or roc).resolve())
    if not args.no_build:
        if 'web' in packages:
            subprocess.run(['zig', 'build', 'build-test-hosts', '-Doptimize=ReleaseSmall'], cwd=ROOT, check=True)
        if 'gui' in packages:
            build_gui(args.debug_gui)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for package in packages:
        package_out = output / package if args.package == 'all' else output
        package_out.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='signals-bundle-') as tmp:
            stage = Path(tmp)
            source = ROOT / ('platform-' + package)
            prepare_platform(source, stage)
            hosts = list((source / 'targets').glob('*/*'))
            hosts = [p for p in hosts if p.suffix in {'.a', '.lib', '.wasm', '.o', '.so', '.json'}]
            if not hosts:
                raise SystemExit(f'No {package} hosts found; run without --no-build.')
            for path in hosts:
                dest = stage / path.relative_to(source)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
            for name in ['LICENSE', 'THIRD_PARTY_LICENSES.md']:
                if (ROOT / name).is_file():
                    shutil.copyfile(ROOT / name, stage / name)
            if package == 'gui':
                shutil.copyfile(ROOT / 'crates/gpui-host/LICENSE-GPUI', stage / 'LICENSE-GPUI')
            files = sorted(str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file())
            result = subprocess.run([roc, 'bundle', *files, '--output-dir', str(package_out)], cwd=stage, text=True, stdout=subprocess.PIPE, check=True)
            print(result.stdout, end='', flush=True)
            created = next((line.split('Created:', 1)[1].strip() for line in result.stdout.splitlines() if 'Created:' in line), None)
            if not created:
                raise SystemExit('roc bundle did not report its output')
            archive = Path(created)
            if not archive.is_absolute():
                archive = stage / archive
            manifest[package] = str(archive.relative_to(output))
    (output / 'bundles.json').write_text(json.dumps(manifest, indent=2) + '\n')
    origin = f'http://127.0.0.1:{args.port}'
    links = '\n'.join(f'<li><a href="{path}">{name} platform</a></li>' for name, path in manifest.items())
    if 'gui' in manifest:
        counter = (ROOT / 'examples-gui/counter/main.roc').read_text().replace('../../platform-gui/main.roc', origin + '/' + manifest['gui'])
        (output / 'Counter.roc').write_text(counter)
        links += '\n<li><a href="Counter.roc">Counter.roc</a> — roc build Counter.roc</li>'
    (output / 'index.html').write_text('<!doctype html><title>Roc Signals platforms</title><h1>Roc Signals platforms</h1><ul>' + links + '</ul>\n')
    for name, path in manifest.items():
        print(f'{name}: {origin}/{path}', flush=True)
    if args.serve:
        print(f'Serving platforms at {origin}/', flush=True)
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(output))
        with http.server.ThreadingHTTPServer(('127.0.0.1', args.port), handler) as server:
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass


if __name__ == '__main__':
    main()
