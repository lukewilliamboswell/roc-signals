#!/usr/bin/env python3
"""Package verified Linux GUI hosts, test URL downloads, and publish an RC.

This CI-only tool deliberately lives outside the host build fingerprint. It
never compiles a host: final platform bytes come from the existing bundler's
verified-host mode, and only application executables are built during checks.
"""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import dependency_artifacts as dependencies
import gui_host_artifacts as hosts
import gui_smoke
import gui_suite
import spec_driver
import toolchain
from host_build_identity import source_fingerprint
from test import BundleServer

REPOSITORY = hosts.REPOSITORY
WORKFLOW = REPOSITORY + '/.github/workflows/gui-release.yml'
BASE = 'https://github.com/' + REPOSITORY + '/releases/download'
TARGET = 'x64glibc'
MANIFEST = 'signals-gui-release.json'
VERSION = re.compile(r'gui-(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-rc\.(?:0|[1-9][0-9]*)')
EXTERNALS = {'freetype-x64glibc', 'glibc-x64glibc', 'unwind-x64glibc', 'xkbcommon-x64glibc'}
HOSTS = {'gui-host-x64glibc', 'gui-host-sources-x64glibc'}


def run(arguments, **kwargs):
    subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def clean_sha(root=ROOT):
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=root, text=True).strip():
        raise ValueError('GUI release requires a clean committed checkout')
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()


def record(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('release asset must be a regular file')
    return {'name': path.name, 'sha256': dependencies.sha256(path), 'size': path.stat().st_size}


def source_url(entry):
    return f"https://github.com/{entry['repository']}/releases/download/{entry['release']}/{entry['asset']}"


def download(url, path, size):
    with urllib.request.urlopen(url, timeout=60) as response, path.open('xb') as output:
        remaining = size
        while remaining:
            data = response.read(min(1024 ** 2, remaining))
            if not data:
                raise ValueError('truncated GUI release asset')
            output.write(data)
            remaining -= len(data)
        if response.read(1):
            raise ValueError('GUI release asset exceeds its expected size')


def read_manifest(directory):
    manifest = json.loads((directory / MANIFEST).read_text())
    if (manifest.get('schema_version') != 1 or not VERSION.fullmatch(manifest['tag'])
            or manifest['targets'] != [TARGET] or not re.fullmatch(r'[0-9a-f]{40}', manifest['source_sha'])
            or manifest['provenance'] != {'signer_workflow': WORKFLOW, 'source_ref': 'refs/heads/main'}):
        raise ValueError('unsupported GUI RC identity')
    if set(manifest['assets']) != {'platform', 'starters', 'host_lock'}:
        raise ValueError('GUI RC requires platform, starters and original host lock')
    expected = {MANIFEST, 'release-notes.md'}
    for item in manifest['assets'].values():
        if not re.fullmatch(r'[A-Za-z0-9._-]+', item['name']):
            raise ValueError('unsafe GUI release asset name')
        if item != dict(record(directory / item['name']), url=f"{BASE}/{manifest['tag']}/{item['name']}"):
            raise ValueError('GUI release asset differs from its manifest')
        expected.add(item['name'])
    if {p.name for p in directory.iterdir()} != expected:
        raise ValueError('unexpected GUI release asset inventory')
    original = dependencies.read_lock(directory / manifest['assets']['host_lock']['name'])
    selected = manifest['dependencies']
    if set(selected['artifacts']) != HOSTS | EXTERNALS or selected['schema_version'] != 1:
        raise ValueError('GUI RC dependency selection is incomplete')
    if any(selected['artifacts'][name] != original['artifacts'][name] for name in HOSTS):
        raise ValueError('GUI RC host selection differs from the original host release')
    companion = selected['artifacts']['gui-host-sources-x64glibc']
    if manifest['source_companions'] != [dict(companion, url=source_url(companion))]:
        raise ValueError('GUI RC source access differs from the host lock')
    return manifest


def inspect_platform(path, manifest):
    """Check the expanded budget, exact receipts, and every retained dependency file."""
    observed, retained = {}, {}
    total = 0
    with subprocess.Popen(['zstd', '-dc', '--', str(path)], stdout=subprocess.PIPE) as decoder:
        try:
            with tarfile.open(fileobj=decoder.stdout, mode='r|') as archive:
                for member in archive:
                    name = member.name
                    parts = Path(name).parts
                    total += member.size
                    if (not member.isfile() or name in observed or not parts or Path(name).is_absolute()
                            or '..' in parts or '\\' in name or total > 100 * 1024 ** 2):
                        raise ValueError('unsafe or oversized GUI platform archive')
                    with archive.extractfile(member) as source:
                        if name == 'dependencies.lock.json' or name.startswith('dependency-manifests/'):
                            if member.size > 4 * 1024 ** 2:
                                raise ValueError('oversized dependency manifest')
                            data = source.read()
                            retained[name] = json.loads(data)
                            digest = hashlib.sha256(data).hexdigest()
                        else:
                            digest = hashlib.file_digest(source, 'sha256').hexdigest()
                    observed[name] = {'sha256': digest, 'size': member.size}
            if decoder.wait() != 0:
                raise ValueError('invalid compressed GUI platform archive')
        finally:
            if decoder.poll() is None:
                decoder.terminate()
    if retained.get('dependencies.lock.json') != manifest['dependencies']:
        raise ValueError('bundled dependency receipt differs from the release')
    identities = EXTERNALS | {'gui-host-x64glibc'}
    if set(retained) != {'dependencies.lock.json'} | {'dependency-manifests/' + name + '.json' for name in identities}:
        raise ValueError('bundled dependency manifests are incomplete')
    declared_targets = {}
    for identity in identities:
        dependency = retained['dependency-manifests/' + identity + '.json']
        if dependency['name'] + '-' + dependency['target'] != identity:
            raise ValueError('bundled dependency identity mismatch')
        if identity == 'gui-host-x64glibc' and dependency['source_fingerprint'] != manifest['host_source_fingerprint']:
            raise ValueError('bundled host source mismatch')
        for name, expected in dependency['files'].items():
            if name.startswith('targets/'):
                if name in declared_targets and declared_targets[name] != expected:
                    raise ValueError('bundled dependency target inventories conflict')
                declared_targets[name] = expected
            if observed.get(name) != expected:
                raise ValueError('bundled dependency file or notice differs from its inventory')
    if any(name.startswith('targets/') and name.split('/')[1] != TARGET for name in observed):
        raise ValueError('Linux GUI RC contains an unselected target')
    if {name for name in observed if name.startswith('targets/')} != set(declared_targets):
        raise ValueError('bundled target inputs differ from the declared dependency inventories')


def extract_starters(path, destination):
    with zipfile.ZipFile(path) as archive:
        seen = set()
        total = 0
        for entry in archive.infolist():
            name = Path(entry.filename)
            total += entry.file_size
            if (entry.filename in seen or name.is_absolute() or '..' in name.parts or '\\' in entry.filename
                    or entry.is_dir() or (entry.external_attr >> 16) & 0o170000 == 0o120000
                    or total > 32 * 1024 ** 2):
                raise ValueError('unsafe or oversized GUI starter archive')
            seen.add(entry.filename)
        archive.extractall(destination)


def prepare(tag, host_release, output, roc, root=ROOT):
    if not VERSION.fullmatch(tag) or not re.fullmatch(r'deps-gui-host-[0-9][A-Za-z0-9.-]*', host_release):
        raise ValueError('use a new gui-X.Y.Z-rc.N tag and an independent host release')
    source = clean_sha(root)
    fingerprint = source_fingerprint(root)
    pin = toolchain.read_pin(root / 'platform-gui/main.roc')
    toolchain.verify_compiler(roc, pin)
    if (root / 'platform-gui/targets').exists():
        raise ValueError('package GUI RCs from a fresh checkout without local target outputs')
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='.gui-release-') as temporary:
        stage = Path(temporary)
        final = stage / 'assets'
        final.mkdir()
        run(['gh', 'release', 'download', host_release, '--repo', REPOSITORY,
             '--pattern', 'dependencies.lock.json', '--dir', stage])
        lock_path = stage / 'dependencies.lock.json'
        run(['gh', 'release', 'verify-asset', host_release, lock_path, '--repo', REPOSITORY])
        original = dependencies.read_lock(lock_path)
        selected = {'schema_version': 1, 'artifacts': {name: original['artifacts'][name] for name in sorted(HOSTS)}}
        if any(entry['release'] != host_release for entry in selected['artifacts'].values()):
            raise ValueError('downloaded host lock names a different release')
        selected_path = stage / 'selected-host.lock.json'
        selected_path.write_text(json.dumps(selected, indent=2) + '\n')
        # Verify source availability and provenance now, without placing its large
        # archive into the Roc bundle. Host admission binds this exact companion.
        companion = selected['artifacts']['gui-host-sources-x64glibc']
        dependencies.fetch(companion, stage / 'source-cache')
        environment = dict(os.environ, ROC_BIN=str(roc))
        run([sys.executable, root / 'scripts/bundle_platforms.py', '--package', 'gui', '--no-build',
             '--prebuilt-host-lock', selected_path, '--output-dir', stage / 'bundle'], cwd=root, env=environment)
        bundled = stage / 'bundle'
        bundle_name = json.loads((bundled / 'bundles.json').read_text())['gui']
        if Path(bundle_name).name != bundle_name:
            raise ValueError('bundler returned an unexpected platform path')
        platform = final / bundle_name
        shutil.copyfile(bundled / bundle_name, platform)
        platform_url = f'{BASE}/{tag}/{platform.name}'
        apps = gui_suite.examples(root)
        with zipfile.ZipFile(final / 'signals-gui-starters.zip', 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(bundled.rglob('*')):
                relative = path.relative_to(bundled)
                if not path.is_file() or relative.parts[0] not in ('examples-gui', 'vendor'):
                    continue
                data = path.read_bytes()
                if relative.parts[0] == 'examples-gui' and relative.name == 'main.roc':
                    if toolchain.read_pin(path) != pin:
                        raise ValueError('GUI starter compiler pin differs from the platform')
                    data = toolchain.replace_platform(data.decode(), platform_url).encode()
                archive.writestr(relative.as_posix(), data)
            archive.writestr('examples-gui/examples.toml', (root / 'examples-gui/examples.toml').read_bytes())
            archive.writestr('README.md', f'Linux x86_64 GUI RC {tag}\n\nCompiler: {pin}\nPlatform: {platform_url}\n\n'
                             'Build: roc build --target=x64glibc examples-gui/counter/main.roc\n'
                             'The compiler and Linux desktop runtime libraries are required; Rust and Zig are not.\n'
                             f'Original host dependency sources: {source_url(companion)}\n'
                             'The platform retains its notices and dependency lock. Preserve them when redistributing.\n')
        shutil.copyfile(lock_path, final / 'host-release.lock.json')
        external = dependencies.read_lock(root / 'dependencies.lock.json')
        selected['artifacts'].update({name: external['artifacts'][name] for name in sorted(EXTERNALS)})
        manifest = {'schema_version': 1, 'tag': tag, 'source_sha': source, 'host_source_fingerprint': fingerprint,
                    'compiler_pin': pin, 'targets': [TARGET], 'examples': [app.name for app in apps],
                    'dependencies': selected, 'source_companions': [dict(companion, url=source_url(companion))],
                    'provenance': {'signer_workflow': WORKFLOW, 'source_ref': 'refs/heads/main'}, 'assets': {}}
        for kind, path in {'platform': platform, 'starters': final / 'signals-gui-starters.zip',
                           'host_lock': final / 'host-release.lock.json'}.items():
            manifest['assets'][kind] = dict(record(path), url=f'{BASE}/{tag}/{path.name}')
        (final / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
        (final / 'release-notes.md').write_text(f'Linux x86_64 GUI release candidate {tag}.\n\n'
            f'Source: {source}. Compiler: {pin}.\n\nAll six maintained GUI applications are built from the served bundle, '
            'run their semantic specs, and confirm rendering through software Vulkan before publication. '
            'Windows and macOS are outside this RC.\n\n'
            f'Host sources and notices remain linked through the included lock: {source_url(companion)}\n')
        read_manifest(final)
        inspect_platform(platform, manifest)
        if clean_sha(root) != source or source_fingerprint(root) != fingerprint:
            raise ValueError('source changed during GUI release packaging')
        final.rename(output)


def check(directory, roc, published=False):
    manifest = read_manifest(directory)
    toolchain.verify_compiler(roc, manifest['compiler_pin'])
    inspect_platform(directory / manifest['assets']['platform']['name'], manifest)
    with tempfile.TemporaryDirectory(prefix='gui-release-check-') as temporary, ExitStack() as contexts:
        stage = Path(temporary)
        extract_starters(directory / manifest['assets']['starters']['name'], stage / 'starter')
        apps = gui_suite.examples(stage / 'starter')
        if [app.name for app in apps] != manifest['examples']:
            raise ValueError('starter application registry differs from the release')
        url = manifest['assets']['platform']['url']
        if not published:
            server = contexts.enter_context(BundleServer(directory))
            url = f"http://127.0.0.1:{server.port}/{manifest['assets']['platform']['name']}"
        environment = dict(os.environ, ROC_CACHE_DIR=str(stage / 'cache'), XDG_CACHE_HOME=str(stage / 'cache'))
        binaries = stage / 'bin'
        binaries.mkdir()
        for app in apps:
            source = app / 'main.roc'
            text = source.read_text()
            span = toolchain.app_platform_span(text)
            if (span is None or text[slice(*span)] != manifest['assets']['platform']['url']
                    or toolchain.read_pin(source) != manifest['compiler_pin']):
                raise ValueError('starter platform URL or compiler pin differs from the release')
            if not published:
                source.write_text(toolchain.replace_platform(text, url))
            executable = binaries / app.name
            run([roc, 'build', '--no-cache', '--target=x64glibc', f'--output={executable}', source],
                cwd=stage, env=environment, timeout=180)
            results = spec_driver.run_suite(executable, app / 'specs', jobs=1)
            spec_driver.print_summary(results)
            if not results or any(not result.passed for result in results):
                raise ValueError(f'GUI RC semantic specs failed: {app.name}')
        # This opens the same binaries just tested above. Call under xvfb-run;
        # Weston and Mesa supply the compositor/input seat/software Vulkan.
        gui_smoke.wayland(binaries)


def verify_attestations(directory, manifest):
    for path in [directory / MANIFEST, *(directory / a['name'] for a in manifest['assets'].values())]:
        run(['gh', 'attestation', 'verify', path, '--repo', REPOSITORY, '--signer-workflow', WORKFLOW,
             '--source-digest', manifest['source_sha'], '--source-ref', 'refs/heads/main', '--deny-self-hosted-runners'])


def publish(directory):
    manifest = read_manifest(directory)
    if (os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_REF') != 'refs/heads/main'
            or os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_SHA') != manifest['source_sha']
            or clean_sha() != manifest['source_sha']):
        raise ValueError('GUI publication requires the tested main dispatch in the producer repository')
    verify_attestations(directory, manifest)
    tag = manifest['tag']
    tags = api(f'repos/{REPOSITORY}/git/matching-refs/tags/{tag}')
    if any(item['ref'] == 'refs/tags/' + tag for item in tags):
        raise ValueError('GUI release tag already exists; recover the original publication')
    # gh refuses an existing release, including a draft without a tag. Create
    # the draft with all exact assets, then publish it once; never replace bytes.
    assets = [directory / MANIFEST, *(directory / a['name'] for a in manifest['assets'].values())]
    run(['gh', 'release', 'create', tag, *assets, '--repo', REPOSITORY, '--target', manifest['source_sha'],
         '--draft', '--prerelease', '--latest=false', '--title', tag, '--notes-file', directory / 'release-notes.md'])
    run(['gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false'])
    published = api(f'repos/{REPOSITORY}/releases/tags/{tag}')
    published_tag = api(f'repos/{REPOSITORY}/git/ref/tags/{tag}')
    if published_tag['object']['sha'] != manifest['source_sha']:
        raise ValueError('published GUI tag differs from the tested source commit')
    if published.get('immutable') is not True:
        raise ValueError('published release is not immutable; repository release immutability must be enabled')
    run(['gh', 'release', 'verify', tag, '--repo', REPOSITORY])


def downloads(directory, roc):
    expected = read_manifest(directory)
    with tempfile.TemporaryDirectory(prefix='gui-release-downloads-') as temporary:
        stage = Path(temporary) / 'assets'
        stage.mkdir()
        original = directory / MANIFEST
        download(f"{BASE}/{expected['tag']}/{MANIFEST}", stage / MANIFEST, original.stat().st_size)
        if (stage / MANIFEST).read_bytes() != original.read_bytes():
            raise ValueError('published GUI metadata differs from the tested manifest')
        shutil.copyfile(directory / 'release-notes.md', stage / 'release-notes.md')
        for item in expected['assets'].values():
            download(item['url'], stage / item['name'], item['size'])
        read_manifest(stage)
        verify_attestations(stage, expected)
        for path in [stage / MANIFEST, *(stage / a['name'] for a in expected['assets'].values())]:
            run(['gh', 'release', 'verify-asset', expected['tag'], path, '--repo', REPOSITORY])
        dependencies.fetch(expected['dependencies']['artifacts']['gui-host-sources-x64glibc'], Path(temporary) / 'source-cache')
        check(stage, roc, published=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'check', 'verify', 'publish', 'downloads'))
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--tag')
    parser.add_argument('--host-release')
    parser.add_argument('--roc', default='roc')
    args = parser.parse_args()
    roc = str(Path(shutil.which(args.roc) or args.roc).resolve())
    directory = args.directory.resolve()
    if args.command == 'prepare':
        prepare(args.tag or '', args.host_release or '', directory, roc)
    elif args.command == 'check':
        check(directory, roc)
    elif args.command == 'verify':
        read_manifest(directory)
    elif args.command == 'publish':
        publish(directory)
    else:
        downloads(directory, roc)


if __name__ == '__main__':
    main()
