#!/usr/bin/env python3
"""Build, bundle, and optionally serve the web and GUI Roc platforms."""
import argparse
import functools
import http.server
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from contextlib import ExitStack

from build_gui import build as build_gui, MACOS_FRAMEWORKS
from prepare_platforms import prepare_platform
from gui_suite import examples as gui_examples
from gui_host_artifacts import verified_hosts, HOST_FILES
from prepare_dependencies import (verified_web_dependencies, WEB_ARTIFACTS,
                                  verified_windows_imports, WINDOWS_IMPORTS,
                                  verified_freetype, FREETYPE,
                                  verified_glibc, GLIBC,
                                  verified_xkbcommon, XKBCOMMON)

ROOT = Path(__file__).resolve().parent.parent


def stage_web_inputs(source, stage):
    """Bundle current host outputs with freshly verified dependency releases.

    An explicit host inventory prevents ignored files left by other builds from
    entering a release. Mutable development libc copies are never bundled.
    """
    hosts = [f"{target}/libhost.a" for target in ("x64mac", "arm64mac", "x64musl", "arm64musl")]
    hosts.append("wasm32/host.wasm")
    for name in hosts:
        path = source / "targets" / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing or invalid web host output: {path}")
    with verified_web_dependencies() as inputs:
        for name in hosts:
            destination = stage / "targets" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / "targets" / name, destination)
        stage_dependency_inputs(inputs, WEB_ARTIFACTS, stage)


def stage_dependency_inputs(inputs, identities, stage):
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


def validate_gui_archives(tree):
    """Reject incomplete or obsolete host layouts before assembling a bundle."""
    for target in ("x64glibc", "arm64mac", "x64win"):
        directory = tree / target
        if not directory.exists():
            continue
        names = (("signals_gpui_host.lib", "engine.lib") if target == "x64win"
                 else ("libsignals_gpui_host.a", "libengine.a"))
        for name in names:
            path = directory / name
            if not path.is_file() or path.is_symlink():
                raise ValueError(f"missing or invalid GUI archive: {path}; rebuild the target directory")


def validate_gui_link_inputs(tree):
    """Do not publish a host-only target as a complete platform target."""
    validate_gui_archives(tree)
    required = []
    if (tree / "x64glibc").is_dir():
        names = ("crt1.o", "crti.o", "crtn.o", "libfreetype.so", "libxkbcommon.so",
                 "libxkbcommon-x11.so", "libgcc_s.so", "libm.so", "libc.so")
        required.extend(tree / "x64glibc" / name for name in names)
    if (tree / "x64win").is_dir():
        required.extend(tree / "x64win" / name for name in ("signals.res", "advapi32.lib"))
    if (tree / "arm64mac").is_dir():
        sdk = tree / "macos-sysroot"
        required.extend(sdk / "usr/lib" / name for name in ("libSystem.tbd", "libobjc.tbd", "libc++.tbd"))
        required.extend(sdk / "System/Library/Frameworks" / (name + ".framework") / (name + ".tbd")
                        for name in MACOS_FRAMEWORKS)
    for path in required:
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing or invalid GUI link dependency: {path}")


def stage_windows_inputs(source, stage):
    """Combine the selected Windows host outputs with newly verified imports."""
    names = ("signals_gpui_host.lib", "engine.lib", "signals.res")
    for name in names:
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing or invalid Windows host output: {path}")
    with verified_windows_imports() as inputs:
        destination = stage / "targets/x64win"
        destination.mkdir(parents=True, exist_ok=True)
        for name in names:
            shutil.copyfile(source / name, destination / name)
        stage_dependency_inputs(inputs, (WINDOWS_IMPORTS,), stage)



def stage_example_package(source, destination):
    """Include a pinned source dependency required by downloadable GUI examples.

    The upstream inventory is the complete admission list. An untracked file or
    a local edit cannot silently become part of the downloaded example package.
    """
    metadata = (source / "upstream.json").read_bytes()
    inventory = json.loads(metadata)["files_sha256"]
    files = {"upstream.json": metadata}
    for name, expected in inventory.items():
        path = source / name
        if Path(name).name != name or "\\" in name or path.is_symlink():
            raise ValueError("unsafe example dependency file")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"example dependency differs from its upstream pin: {path}")
        files[name] = data
    if destination.exists():
        actual = {path.relative_to(destination).as_posix(): path.read_bytes()
                  for path in destination.rglob("*") if path.is_file()}
        if actual != files or any(path.is_symlink() for path in destination.rglob("*")):
            raise ValueError("example dependency output differs; use a fresh bundle output directory")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".example-package-") as temporary:
        stage = Path(temporary) / "package"
        stage.mkdir()
        for name, data in files.items():
            (stage / name).write_bytes(data)
        stage.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', choices=['all', 'web', 'gui'], default='all')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--debug-gui', action='store_true')
    parser.add_argument('--prebuilt-host-lock', type=Path, action='append', default=[],
                        help='Verified GUI host release lock to include alongside local targets')
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
        # Roc publishes its cwd-local temporary archive with rename. Keep the
        # source staging tree on the output filesystem (upstream bug 14).
        with tempfile.TemporaryDirectory(prefix='.signals-bundle-', dir=package_out) as tmp, ExitStack() as resources:
            stage = Path(tmp)
            source = ROOT / ('platform-' + package)
            prepare_platform(source, stage)
            trees = []
            if package == 'web':
                stage_web_inputs(source, stage)
            if package == 'gui':
                trees = [source / 'targets'] if (source / 'targets').is_dir() else []
                for lock in args.prebuilt_host_lock:
                    inputs = resources.enter_context(verified_hosts(
                        lock.resolve(), Path.home() / '.cache/roc-signals/dependencies', ROOT))
                    receipt = json.loads((inputs / 'dependencies.lock.json').read_text())
                    identities = tuple(identity for identity, entry in receipt['artifacts'].items()
                                       if entry.get('name') != 'gui-host-sources')
                    trees.extend(inputs / identity / 'targets' for identity in identities)
                    stage_dependency_inputs(inputs, identities, stage)
            hosts = []
            windows_targets = []
            selected_targets = set()
            for tree in trees:
                if not tree.is_dir():
                    raise SystemExit(f'Prebuilt targets directory not found: {tree}')
                for target, names in HOST_FILES.items():
                    if any((tree / target / name).exists() for name in (*names, 'libhost.a', 'host.lib')):
                        for name in names:
                            path = tree / target / name
                            if not path.is_file() or path.is_symlink():
                                raise ValueError(f'missing or invalid GUI host output: {path}')
                        if target in selected_targets:
                            raise ValueError(f'select one local or verified host tree for {target}')
                        selected_targets.add(target)
                if (tree / 'x64win/signals_gpui_host.lib').is_file():
                    windows_targets.append(tree / 'x64win')
                hosts += [(tree, p) for p in tree.rglob('*')
                          if p.is_file() and p.relative_to(tree).parts[0] != 'x64win'
                          and (p.relative_to(tree).parts[0] != 'x64glibc'
                               or p.relative_to(tree).as_posix() in {
                                   'x64glibc/libsignals_gpui_host.a', 'x64glibc/libengine.a',
                                   'x64glibc/libgcc_s.so', 'x64glibc/link-inputs.json'})
                          and p.suffix in {'.a', '.lib', '.res', '.wasm', '.o', '.so', '.json', '.tbd'}]
            if package == 'gui' and not hosts and not windows_targets:
                raise SystemExit(f'No {package} hosts found; run without --no-build.')
            for tree, path in hosts:
                dest = stage / 'targets' / path.relative_to(tree)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
            if len(windows_targets) > 1:
                raise ValueError('select one Windows host tree; overlapping local/prebuilt hosts are ambiguous')
            if windows_targets:
                stage_windows_inputs(windows_targets[0], stage)
            if any((tree / 'x64glibc').is_dir() for tree in trees):
                with verified_freetype() as inputs:
                    stage_dependency_inputs(inputs, (FREETYPE,), stage)
                with verified_glibc() as inputs:
                    stage_dependency_inputs(inputs, (GLIBC,), stage)
                with verified_xkbcommon() as inputs:
                    stage_dependency_inputs(inputs, (XKBCOMMON,), stage)
            if package == 'gui':
                validate_gui_link_inputs(stage / 'targets')
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
    (output / 'bundles.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    origin = f'http://127.0.0.1:{args.port}'
    links = '\n'.join(f'<li><a href="{path}">{name} platform</a></li>' for name, path in manifest.items())
    if 'gui' in manifest:
        stage_example_package(ROOT / 'vendor/unicode', output / 'vendor/unicode')
        counter = (ROOT / 'examples-gui/counter/main.roc').read_text(encoding='utf-8').replace('../../platform-gui/main.roc', origin + '/' + manifest['gui'])
        (output / 'Counter.roc').write_text(counter, encoding='utf-8')
        links += '\n<li><a href="Counter.roc">Counter.roc</a> — roc build Counter.roc</li>'
        for app in gui_examples():
            destination = output / 'examples-gui' / app.name
            for source in sorted(app.rglob('*')):
                if source.is_file() and source.suffix in {'.roc', '.scm'}:
                    dest = destination / source.relative_to(app)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    content = source.read_text(encoding='utf-8').replace('../../platform-gui/main.roc', origin + '/' + manifest['gui'])
                    dest.write_text(content, encoding='utf-8')
            links += f'\n<li><a href="examples-gui/{app.name}/">{app.name} sources and specs</a></li>'
    (output / 'index.html').write_text('<!doctype html><title>Roc Signals platforms</title><h1>Roc Signals platforms</h1><ul>' + links + '</ul>\n', encoding='utf-8')
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
