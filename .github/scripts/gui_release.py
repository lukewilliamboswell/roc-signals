#!/usr/bin/env python3
"""Package verified GUI hosts, test URL downloads, and publish an RC.

This CI-only tool deliberately lives outside the host build fingerprint. It
never compiles a host: final platform bytes come from the existing bundler's
verified-host mode, and only application executables are built during checks.
"""

import argparse
from contextlib import ExitStack
import hashlib
import json
import os
import platform
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
TARGET_EXTERNALS = {
    'x64glibc': EXTERNALS,
    'arm64mac': set(),
    'x64mingw': {'windows-system-imports-x64mingw', 'windows-gnu-runtime-x64mingw'},
}
NATIVE_TARGETS = {'x64glibc': ('Linux', {'x86_64', 'amd64'}),
                  'arm64mac': ('Darwin', {'arm64', 'aarch64'}),
                  'x64mingw': ('Windows', {'amd64', 'x86_64'})}


def selected_target(manifest):
    targets = manifest.get('targets')
    if not isinstance(targets, list) or len(targets) != 1 or targets[0] not in TARGET_EXTERNALS:
        raise ValueError('GUI RC requires exactly one supported target')
    return targets[0]


def host_identities(target):
    return {'gui-host-' + target, 'gui-host-sources-' + target}


def require_native(target):
    system, machines = NATIVE_TARGETS[target]
    if platform.system() != system or platform.machine().lower() not in machines:
        raise ValueError('GUI RC execution requires a native ' + target + ' runner')


def require_preparation_support(target, root=ROOT):
    if target not in TARGET_EXTERNALS:
        raise ValueError('unsupported GUI RC target')
    if target == 'x64mingw':
        from prepare_dependencies import windows_gnu_files
        lock = dependencies.read_lock(root / 'dependencies.lock.json')
        for identity in TARGET_EXTERNALS[target]:
            entry = lock['artifacts'].get(identity)
            if entry is None or entry['target'] != target or entry['name'] + '-' + target != identity:
                raise ValueError('Windows RC requires independently released runtime and complete imports')
        header = (root / 'platform-gui/main.roc').read_text()
        block = re.search(r'x64mingw:\s*\{\s*inputs:\s*\[(.*?)\]', header, re.S)
        observed = [] if block is None else [left or right for left, right in re.findall(r'"([^"\n]+)"|\b(app)\b', block[1])]
        files = windows_gnu_files()
        expected = [files[0], 'libsignals_gpui_host.a', 'libengine.a', 'signals.res', 'app', *files[1:]]
        if observed != expected:
            raise ValueError('Windows RC header differs from complete reviewed link inputs and provider order')


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
    target = selected_target(manifest)
    if (manifest.get('schema_version') != 1 or not VERSION.fullmatch(manifest['tag'])
            or not re.fullmatch(r'[0-9a-f]{40}', manifest['source_sha'])
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
    if set(selected['artifacts']) != host_identities(target) | TARGET_EXTERNALS[target] or selected['schema_version'] != 1:
        raise ValueError('GUI RC dependency selection is incomplete')
    if any(selected['artifacts'][name] != original['artifacts'][name] for name in host_identities(target)):
        raise ValueError('GUI RC host selection differs from the original host release')
    companion = selected['artifacts']['gui-host-sources-' + target]
    if manifest['source_companions'] != [dict(companion, url=source_url(companion))]:
        raise ValueError('GUI RC source access differs from the host lock')
    return manifest


def macos_interfaces(observed, retained, manifest):
    """Admit only exact project catalog outputs bound to the selected host bytes."""
    import build_macos_stubs as stubs
    prefix = 'targets/macos-sysroot/'
    catalog = stubs.CATALOG.read_bytes()
    provenance = stubs.PROVENANCE.read_bytes()
    generated = stubs.render(stubs.validate_catalog(json.loads(catalog)))
    generated.update({'interfaces.json': catalog, 'PROVENANCE.md': provenance})
    record_path = prefix + 'manifest.json'
    recorded = retained.get(record_path)
    expected = {'schema_version': 1, 'origin': 'project-generated-macos-interfaces',
                'target': 'arm64-macos',
                'host_archives_sha256': {name: observed['targets/arm64mac/' + name]['sha256'] for name in stubs.ARCHIVES},
                'catalog_sha256': stubs.digest(catalog), 'generator_sha256': stubs.digest(Path(stubs.__file__).read_bytes()),
                'provenance_sha256': stubs.digest(provenance),
                'files_sha256': {name: stubs.digest(data) for name, data in generated.items()
                                 if name not in ('interfaces.json', 'PROVENANCE.md')}}
    if recorded != expected:
        raise ValueError('Mac interface manifest differs from project catalog or selected host')
    validation = retained.get(prefix + 'validation.json', {})
    if (set(validation) != {'schema_version', 'compiler_pin', 'examples', 'interface_manifest_sha256'}
            or validation['schema_version'] != 1 or validation['compiler_pin'] != manifest['compiler_pin']
            or validation['interface_manifest_sha256'] != observed[record_path]['sha256']
            or set(validation['examples']) != set(manifest['examples'])
            or any(type(count) is not int or count <= 0 for count in validation['examples'].values())):
        raise ValueError('Mac interface native validation differs from the selected bundle')
    expected_files = {prefix + name: {'sha256': stubs.digest(data), 'size': len(data)} for name, data in generated.items()}
    expected_files.update({name: observed[name] for name in (record_path, prefix + 'validation.json')})
    if any(observed.get(name) != entry for name, entry in expected_files.items()):
        raise ValueError('Mac interface bytes differ from project-generated catalog outputs')
    return expected_files


def inspect_platform(path, manifest):
    """Check the expanded budget, exact receipts, and every retained dependency file."""
    target = selected_target(manifest)
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
                            or name != Path(name).as_posix()
                            or '..' in parts or '\\' in name or total > 100 * 1024 ** 2):
                        raise ValueError('unsafe or oversized GUI platform archive')
                    with archive.extractfile(member) as source:
                        if (name == 'dependencies.lock.json' or name.startswith('dependency-manifests/')
                                or name in ('targets/macos-sysroot/manifest.json', 'targets/macos-sysroot/validation.json')):
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
    identities = TARGET_EXTERNALS[target] | {'gui-host-' + target}
    interface_records = {'targets/macos-sysroot/manifest.json', 'targets/macos-sysroot/validation.json'} if target == 'arm64mac' else set()
    if set(retained) != {'dependencies.lock.json'} | interface_records | {'dependency-manifests/' + name + '.json' for name in identities}:
        raise ValueError('bundled dependency manifests are incomplete')
    declared_targets = {}
    for identity in identities:
        dependency = retained['dependency-manifests/' + identity + '.json']
        if dependency['name'] + '-' + dependency['target'] != identity:
            raise ValueError('bundled dependency identity mismatch')
        if identity == 'gui-host-' + target and dependency['source_fingerprint'] != manifest['host_source_fingerprint']:
            raise ValueError('bundled host source mismatch')
        for name, expected in dependency['files'].items():
            if name.startswith('targets/'):
                if name in declared_targets and declared_targets[name] != expected:
                    raise ValueError('bundled dependency target inventories conflict')
                declared_targets[name] = expected
            if observed.get(name) != expected:
                raise ValueError('bundled dependency file or notice differs from its inventory')
    if target == 'arm64mac':
        declared_targets.update(macos_interfaces(observed, retained, manifest))
    allowed = {target, 'macos-sysroot'} if target == 'arm64mac' else {target}
    if any(name.startswith('targets/') and name.split('/')[1] not in allowed for name in observed):
        raise ValueError('GUI RC contains an unselected target')
    if {name for name in observed if name.startswith('targets/')} != set(declared_targets):
        raise ValueError('bundled target inputs differ from the declared dependency inventories')


def extract_starters(path, destination):
    with zipfile.ZipFile(path) as archive:
        seen = set()
        total = 0
        for entry in archive.infolist():
            name = Path(entry.filename)
            total += entry.file_size
            if (entry.filename in seen or not name.parts or entry.filename != name.as_posix()
                    or name.is_absolute() or '..' in name.parts or '\\' in entry.filename
                    or entry.is_dir() or (entry.external_attr >> 16) & 0o170000 == 0o120000
                    or total > 32 * 1024 ** 2):
                raise ValueError('unsafe or oversized GUI starter archive')
            seen.add(entry.filename)
        archive.extractall(destination)


def prepare(tag, host_release, output, roc, root=ROOT, target=TARGET):
    require_preparation_support(target, root)
    require_native(target)
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
        selected = {'schema_version': 1, 'artifacts': {name: original['artifacts'][name] for name in sorted(host_identities(target))}}
        if any(entry['release'] != host_release for entry in selected['artifacts'].values()):
            raise ValueError('downloaded host lock names a different release')
        selected_path = stage / 'selected-host.lock.json'
        selected_path.write_text(json.dumps(selected, indent=2) + '\n')
        # Verify source availability and provenance now, without placing its large
        # archive into the Roc bundle. Host admission binds this exact companion.
        companion = selected['artifacts']['gui-host-sources-' + target]
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
            archive.writestr('README.md', f'{target} GUI RC {tag}\n\nCompiler: {pin}\nPlatform: {platform_url}\n\n'
                             f'Build: roc build --target={target} examples-gui/counter/main.roc\n'
                             'The pinned compiler and target operating-system runtime are required; Rust and Zig are not.\n'
                             f'Original host dependency sources: {source_url(companion)}\n'
                             'The platform retains its notices and dependency lock. Preserve them when redistributing.\n')
        shutil.copyfile(lock_path, final / 'host-release.lock.json')
        external = dependencies.read_lock(root / 'dependencies.lock.json')
        selected['artifacts'].update({name: external['artifacts'][name] for name in sorted(TARGET_EXTERNALS[target])})
        manifest = {'schema_version': 1, 'tag': tag, 'source_sha': source, 'host_source_fingerprint': fingerprint,
                    'compiler_pin': pin, 'targets': [target], 'examples': [app.name for app in apps],
                    'dependencies': selected, 'source_companions': [dict(companion, url=source_url(companion))],
                    'provenance': {'signer_workflow': WORKFLOW, 'source_ref': 'refs/heads/main'}, 'assets': {}}
        for kind, path in {'platform': platform, 'starters': final / 'signals-gui-starters.zip',
                           'host_lock': final / 'host-release.lock.json'}.items():
            manifest['assets'][kind] = dict(record(path), url=f'{BASE}/{tag}/{path.name}')
        (final / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
        (final / 'release-notes.md').write_text(f'{target} GUI release candidate {tag}.\n\n'
            f'Source: {source}. Compiler: {pin}.\n\nAll six maintained GUI applications are built from the served bundle, '
            'run their semantic specs, and confirm native rendering before publication. '
            'This RC contains only its selected target.\n\n'
            f'Host sources and notices remain linked through the included lock: {source_url(companion)}\n')
        read_manifest(final)
        inspect_platform(platform, manifest)
        if clean_sha(root) != source or source_fingerprint(root) != fingerprint:
            raise ValueError('source changed during GUI release packaging')
        final.rename(output)


def check(directory, roc, published=False):
    manifest = read_manifest(directory)
    target = selected_target(manifest)
    require_native(target)
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
            executable = binaries / (app.name + ('.exe' if target == 'x64mingw' else ''))
            run([roc, 'build', '--no-cache', f'--target={target}', f'--output={executable}', source],
                cwd=stage, env=environment, timeout=180)
            results = spec_driver.run_suite(executable, app / 'specs', jobs=1)
            spec_driver.print_summary(results)
            if not results or any(not result.passed for result in results):
                raise ValueError(f'GUI RC semantic specs failed: {app.name}')
        # This opens the same binaries just tested above. Call under xvfb-run;
        # Weston and Mesa supply the compositor/input seat/software Vulkan.
        (gui_smoke.wayland if target == 'x64glibc' else gui_smoke.run)(binaries)


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
        dependencies.fetch(expected['dependencies']['artifacts']['gui-host-sources-' + selected_target(expected)], Path(temporary) / 'source-cache')
        check(stage, roc, published=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'check', 'verify', 'publish', 'downloads'))
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--target', choices=sorted(TARGET_EXTERNALS), default=TARGET)
    parser.add_argument('--tag')
    parser.add_argument('--host-release')
    parser.add_argument('--roc', default='roc')
    args = parser.parse_args()
    roc = str(Path(shutil.which(args.roc) or args.roc).resolve())
    directory = args.directory.resolve()
    if args.command == 'prepare':
        prepare(args.tag or '', args.host_release or '', directory, roc, target=args.target)
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
