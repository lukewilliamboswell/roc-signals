#!/usr/bin/env python3
"""Build, bundle, and optionally serve the web Roc platform."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from contextlib import ExitStack

from prepare_platforms import prepare_platform
from web_host_artifacts import IDENTITIES as WEB_HOSTS, OUTPUTS as WEB_HOST_OUTPUTS
from web_host_artifacts import verified_hosts as verified_web_hosts
from prepare_dependencies import verified_web_dependencies, WEB_ARTIFACTS

ROOT = Path(__file__).resolve().parent.parent


def stage_web_inputs(source, stage, host_lock=None):
    """Stage explicit local hosts or a content-hash-verified immutable host set.

    All external linker inputs are independently verified before staging starts.
    An explicit inventory prevents ignored build files from entering a bundle.
    """
    hosts = tuple(f"{target}/{name}" for target, name in WEB_HOST_OUTPUTS.items())
    with ExitStack() as resources:
        dependency_inputs = resources.enter_context(verified_web_dependencies())
        if host_lock is None:
            host_sources = {name: source / "targets" / name for name in hosts}
            host_inputs = None
        else:
            host_inputs = resources.enter_context(verified_web_hosts(
                host_lock.resolve(), Path.home() / ".cache/roc-signals/dependencies", ROOT))
            host_sources = {
                f"{target}/{name}": host_inputs / ("web-host-" + target) / "targets" / target / name
                for target, name in WEB_HOST_OUTPUTS.items()
            }
        for name, path in host_sources.items():
            if not path.is_file() or path.is_symlink():
                raise ValueError(f"missing or invalid web host output: {path}")
            destination = stage / "targets" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        if host_lock is not None:
            stage_dependency_inputs(host_inputs, WEB_HOSTS, stage)
        stage_dependency_inputs(dependency_inputs, WEB_ARTIFACTS, stage)


def stage_dependency_inputs(inputs, identities, stage):
    """Stage admitted inputs and merge their lock receipts, rejecting conflicts."""
    receipt = json.loads((inputs / "dependencies.lock.json").read_text())
    receipt_path = stage / "dependencies.lock.json"
    if receipt_path.exists():
        existing = json.loads(receipt_path.read_text())
        for identity, entry in existing["artifacts"].items():
            if identity in receipt["artifacts"] and receipt["artifacts"][identity] != entry:
                raise ValueError(f"conflicting dependency receipt: {identity}")
            receipt["artifacts"][identity] = entry
    for identity in identities:
        for path in (inputs / identity).rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(inputs / identity)
            if relative.as_posix() == "dependency.json":
                relative = Path("dependency-manifests") / (identity + ".json")
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                if destination.read_bytes() != path.read_bytes():
                    raise ValueError(f"conflicting dependency input: {relative}")
            else:
                shutil.copyfile(path, destination)
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--prebuilt-web-host-lock', type=Path,
                        help='Verified complete web host release lock to use instead of local targets')
    parser.add_argument('--output-dir', type=Path, default=Path(os.environ.get('BUNDLE_OUT_DIR', str(ROOT / '.test-out/bundles'))))
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    roc = os.environ.get('ROC_BIN', os.environ.get('ROC', 'roc'))
    # Resolve before running from the staging directory; callers may pass a relative path.
    roc = str(Path(shutil.which(roc) or roc).resolve())
    if not args.no_build:
        subprocess.run(['zig', 'build', 'build-test-hosts', '-Doptimize=ReleaseSmall'], cwd=ROOT, check=True)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Roc publishes its cwd-local temporary archive with rename. Keep the
    # source staging tree on the output filesystem (upstream bug 14).
    with tempfile.TemporaryDirectory(prefix='.signals-bundle-', dir=output) as tmp:
        stage = Path(tmp)
        source = ROOT / 'platform-web'
        prepare_platform(source, stage)
        stage_web_inputs(source, stage, args.prebuilt_web_host_lock)
        for name in ['LICENSE', 'THIRD_PARTY_LICENSES.md']:
            if (ROOT / name).is_file():
                shutil.copyfile(ROOT / name, stage / name)
        files = sorted(str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file())
        # TODO(upstream): drop this reordering once Linux `roc bundle` resolves
        # hosted declarations independently of argument order
        # (https://github.com/roc-lang/roc/issues/12565); listing the platform
        # root after its hosted type modules fails there.
        files.remove('main.roc')
        files.insert(0, 'main.roc')
        result = subprocess.run([roc, 'bundle', *files, '--output-dir', str(output)], cwd=stage, text=True, stdout=subprocess.PIPE, check=True)
        print(result.stdout, end='', flush=True)
        created = next((line.split('Created:', 1)[1].strip() for line in result.stdout.splitlines() if 'Created:' in line), None)
        if not created:
            raise SystemExit('roc bundle did not report its output')
        archive = Path(created)
        if not archive.is_absolute():
            archive = stage / archive
        manifest = {'web': str(archive.resolve().relative_to(output))}
    (output / 'bundles.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    origin = f'http://127.0.0.1:{args.port}'
    links = '\n'.join(f'<li><a href="{path}">{name} platform</a></li>' for name, path in manifest.items())
    (output / 'index.html').write_text('<!doctype html><title>Roc Signals platform</title><h1>Roc Signals platform</h1><ul>' + links + '</ul>\n', encoding='utf-8')
    for name, path in manifest.items():
        print(f'{name}: {origin}/{path}', flush=True)
    if args.serve:
        print(f'Serving the platform at {origin}/', flush=True)
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(output))
        with http.server.ThreadingHTTPServer(('127.0.0.1', args.port), handler) as server:
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass


if __name__ == '__main__':
    main()
