"""GUI packaging preserves provenance boundaries and tests the served bytes."""

from contextlib import ExitStack
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch
import urllib.request
import zipfile

import gui_release as release


class GuiReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'assets'
        self.output.mkdir()
        self.tag = 'gui-0.1.0-rc.1'
        self.pin = 'nightly-2026-09-04-c125b82'
        self.sha = 'a' * 40
        self.slugs = [app.name for app in release.gui_suite.examples()]
        self.lock = {'schema_version': 1, 'artifacts': {}}
        for identity in sorted(release.HOSTS | release.EXTERNALS):
            name = identity.removesuffix('-x64glibc')
            self.lock['artifacts'][identity] = {
                'name': name, 'target': 'x64glibc', 'repository': release.REPOSITORY,
                'release': 'deps-gui-host-1' if identity in release.HOSTS else 'deps-' + name + '-1',
                'asset': identity + '.tar', 'sha256': 'b' * 64, 'size': 123,
                'source_sha': self.sha, 'source_ref': 'refs/heads/main',
                'signer_workflow': release.REPOSITORY + '/.github/workflows/gui-hosts.yml'}
        host_lock = {'schema_version': 1, 'artifacts': {name: self.lock['artifacts'][name] for name in release.HOSTS}}
        (self.output / 'host-release.lock.json').write_text(json.dumps(host_lock))
        (self.output / 'platform.tar.zst').write_bytes(b'exact served platform')
        url = f'{release.BASE}/{self.tag}/platform.tar.zst'
        with zipfile.ZipFile(self.output / 'signals-gui-starters.zip', 'w') as archive:
            archive.writestr('examples-gui/examples.toml', (release.ROOT / 'examples-gui/examples.toml').read_bytes())
            for slug in self.slugs:
                archive.writestr(f'examples-gui/{slug}/main.roc', f'app [main] {{ roc: "{self.pin}", pf: platform "{url}" }}\nmain = 1\n')
                archive.writestr(f'examples-gui/{slug}/specs/example.scm', '(expect-text "example")\n')
        companion = self.lock['artifacts']['gui-host-sources-x64glibc']
        self.manifest = {'schema_version': 1, 'tag': self.tag, 'source_sha': self.sha,
                         'host_source_fingerprint': 'fingerprint', 'targets': ['x64glibc'], 'compiler_pin': self.pin,
                         'examples': self.slugs, 'dependencies': self.lock,
                         'source_companions': [dict(companion, url=release.source_url(companion))],
                         'provenance': {'signer_workflow': release.WORKFLOW, 'source_ref': 'refs/heads/main'}, 'assets': {}}
        for kind, name in {'platform': 'platform.tar.zst', 'starters': 'signals-gui-starters.zip', 'host_lock': 'host-release.lock.json'}.items():
            self.manifest['assets'][kind] = dict(release.record(self.output / name), url=f'{release.BASE}/{self.tag}/{name}')
        self.save_manifest()
        (self.output / 'release-notes.md').write_text('Linux only')

    def save_manifest(self):
        (self.output / release.MANIFEST).write_text(json.dumps(self.manifest))

    def test_manifest_rejects_changed_assets_sources_and_extra_files(self):
        release.read_manifest(self.output)
        source = self.manifest['source_companions'][0]['url']
        self.manifest['source_companions'][0]['url'] = 'https://other.invalid/source'
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'source access'):
            release.read_manifest(self.output)
        self.manifest['source_companions'][0]['url'] = source
        self.save_manifest()
        (self.output / 'injected.a').write_bytes(b'unknown')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            release.read_manifest(self.output)
        (self.output / 'injected.a').unlink()
        (self.output / 'platform.tar.zst').write_bytes(b'rebuilt')
        with self.assertRaisesRegex(ValueError, 'differs'):
            release.read_manifest(self.output)

    def test_prepare_uses_only_verified_bundle_mode_and_preserves_pins(self):
        commands = []
        def command(arguments, **kwargs):
            arguments = list(map(str, arguments))
            commands.append(arguments)
            if arguments[:3] == ['gh', 'release', 'download']:
                destination = Path(arguments[arguments.index('--dir') + 1])
                (destination / 'dependencies.lock.json').write_bytes((self.output / 'host-release.lock.json').read_bytes())
            elif 'scripts/bundle_platforms.py' in arguments[1]:
                self.assertIn('--no-build', arguments)
                self.assertIn('--prebuilt-host-lock', arguments)
                destination = Path(arguments[arguments.index('--output-dir') + 1])
                destination.mkdir()
                (destination / 'bundles.json').write_text('{"gui":"platform.tar.zst"}')
                (destination / 'platform.tar.zst').write_bytes(b'packaged verified host')
                for slug in self.slugs:
                    app = destination / 'examples-gui' / slug
                    app.mkdir(parents=True)
                    (app / 'main.roc').write_text(f'app [main] {{ roc: "{self.pin}", pf: platform "http://127.0.0.1:8000/platform.tar.zst" }}\nmain = 1\n')
        output = self.root / 'prepared'
        with patch.object(release, 'clean_sha', return_value=self.sha), \
                patch.object(release, 'source_fingerprint', return_value='fingerprint'), \
                patch.object(release.toolchain, 'verify_compiler'), patch.object(release.dependencies, 'fetch') as source, \
                patch.object(release, 'inspect_platform'), patch.object(release, 'run', side_effect=command):
            release.prepare(self.tag, 'deps-gui-host-1', output, 'roc')
            source.assert_called_once()
        self.assertEqual(len(commands), 3)  # Original lock download/verification, then verified bundle mode.
        self.assertFalse(any(command[0] in ('cargo', 'zig') for command in commands))
        manifest = release.read_manifest(output)
        with zipfile.ZipFile(output / 'signals-gui-starters.zip') as archive:
            self.assertIn('examples-gui/examples.toml', archive.namelist())
            for slug in self.slugs:
                text = archive.read(f'examples-gui/{slug}/main.roc').decode()
                self.assertIn(self.pin, text)
                self.assertEqual(text[slice(*release.toolchain.app_platform_span(text))], manifest['assets']['platform']['url'])

    def test_candidate_builds_every_app_from_actual_http_without_changing_release_sources(self):
        before = (self.output / 'signals-gui-starters.zip').read_bytes()
        observed = []
        def build(command, **kwargs):
            self.assertEqual(command[1:4], ['build', '--no-cache', '--target=x64glibc'])
            path = Path(command[-1])
            text = path.read_text()
            url = text[slice(*release.toolchain.app_platform_span(text))]
            self.assertTrue(url.startswith('http://127.0.0.1:'))
            with urllib.request.urlopen(url) as response:
                self.assertEqual(response.read(), b'exact served platform')
            self.assertIn('ROC_CACHE_DIR', kwargs['env'])
            executable = Path(command[-2].removeprefix('--output='))
            executable.write_bytes(b'application binary')
            observed.append(executable.name)
        def smoke(directory):
            self.assertEqual({p.name for p in directory.iterdir()}, set(self.slugs))
        with patch.object(release.toolchain, 'verify_compiler'), patch.object(release, 'inspect_platform'), \
                patch.object(release, 'run', side_effect=build), \
                patch.object(release.spec_driver, 'run_suite', return_value=[types.SimpleNamespace(passed=True)]), \
                patch.object(release.spec_driver, 'print_summary'), patch.object(release.gui_smoke, 'wayland', side_effect=smoke) as rendered:
            release.check(self.output, 'roc')
        self.assertEqual(observed, self.slugs)
        rendered.assert_called_once()
        self.assertEqual((self.output / 'signals-gui-starters.zip').read_bytes(), before)

    def test_published_checks_preserve_public_urls(self):
        expected = self.manifest['assets']['platform']['url']
        observed = []
        def build(command, **kwargs):
            source = Path(command[-1]).read_text()
            observed.append(source[slice(*release.toolchain.app_platform_span(source))])
        with patch.object(release.toolchain, 'verify_compiler'), patch.object(release, 'inspect_platform'), \
                patch.object(release, 'run', side_effect=build), \
                patch.object(release.spec_driver, 'run_suite', return_value=[types.SimpleNamespace(passed=True)]), \
                patch.object(release.spec_driver, 'print_summary'), patch.object(release.gui_smoke, 'wayland'):
            release.check(self.output, 'roc', published=True)
        self.assertEqual(observed, [expected] * len(self.slugs))

    def test_empty_specs_refuse_render_and_publication(self):
        with patch.object(release.toolchain, 'verify_compiler'), patch.object(release, 'inspect_platform'), \
                patch.object(release, 'run'), patch.object(release.spec_driver, 'run_suite', return_value=[]), \
                patch.object(release.spec_driver, 'print_summary'), patch.object(release.gui_smoke, 'wayland') as render:
            with self.assertRaisesRegex(ValueError, 'semantic specs failed'):
                release.check(self.output, 'roc')
            render.assert_not_called()

    def test_packaging_files_do_not_change_host_identity_but_host_files_do(self):
        root = self.root / 'repository'
        root.mkdir()
        subprocess.run(['git', 'init', '--quiet', root], check=True)
        (root / 'src').mkdir()
        (root / 'src/engine.zig').write_text('host input')
        def commit():
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                            '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'fixture'], cwd=root, check=True)
        commit()
        original = release.source_fingerprint(root)
        for relative in ('.github/scripts/gui_release.py', '.github/scripts/test_gui_release.py',
                         '.github/workflows/gui-release.yml', 'www/content/docs/contributing.md'):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('packaging only')
        commit()
        self.assertEqual(release.source_fingerprint(root), original)
        (root / 'src/engine.zig').write_text('changed host input')
        with self.assertRaisesRegex(ValueError, 'clean committed'):
            release.source_fingerprint(root)
        commit()
        self.assertNotEqual(release.source_fingerprint(root), original)

    def test_platform_retains_every_original_dependency_notice(self):
        files = {'dependencies.lock.json': json.dumps(self.lock).encode()}
        for identity in release.EXTERNALS | {'gui-host-x64glibc'}:
            name = identity.removesuffix('-x64glibc')
            path = f'licenses/{name}/NOTICE'
            data = ('original notice: ' + identity).encode()
            files[path] = data
            dependency = {'name': name, 'target': 'x64glibc', 'source_fingerprint': 'fingerprint',
                          'files': {path: {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}}}
            native = f'targets/x64glibc/{name}.a'
            files[native] = b'declared native input'
            dependency['files'][native] = {'sha256': hashlib.sha256(files[native]).hexdigest(), 'size': len(files[native])}
            files['dependency-manifests/' + identity + '.json'] = json.dumps(dependency).encode()
        def pack():
            raw = io.BytesIO()
            with tarfile.open(fileobj=raw, mode='w') as archive:
                for name, data in files.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            compressed = subprocess.check_output(['zstd', '-q', '-c'], input=raw.getvalue())
            path = self.root / 'notice-platform.tar.zst'
            path.write_bytes(compressed)
            return path
        release.inspect_platform(pack(), self.manifest)
        for extra, error in (('targets/x64glibc/unverified.a', 'declared dependency inventories'),
                             ('targets/x64win/unverified.lib', 'unselected target'),
                             ('./targets/x64glibc/gui-host.a', 'unsafe'),
                             ('targets//x64glibc/gui-host.a', 'unsafe'),
                             ('targets/x64glibc/./gui-host.a', 'unsafe')):
            with self.subTest(extra=extra):
                files[extra] = b'unverified input'
                with self.assertRaisesRegex(ValueError, error):
                    release.inspect_platform(pack(), self.manifest)
                del files[extra]
        missing = files.pop('targets/x64glibc/gui-host.a')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            release.inspect_platform(pack(), self.manifest)
        files['targets/x64glibc/gui-host.a'] = missing
        del files['licenses/gui-host/NOTICE']
        with self.assertRaisesRegex(ValueError, 'notice differs'):
            release.inspect_platform(pack(), self.manifest)

    def test_unsafe_starters_are_rejected(self):
        path = self.root / 'unsafe.zip'
        for name in ('../outside', './examples-gui/counter/main.roc',
                     'examples-gui//counter/main.roc', 'examples-gui/counter/./main.roc'):
            with self.subTest(name=name):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr(name, b'unsafe')
                with self.assertRaisesRegex(ValueError, 'unsafe'):
                    release.extract_starters(path, self.root / 'extract')

    def test_publication_refuses_nonmain_and_existing_tags(self):
        with patch.dict(release.os.environ, {'GITHUB_EVENT_NAME': 'pull_request'}, clear=True), \
                patch.object(release, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'main dispatch'):
                release.publish(self.output)
            run.assert_not_called()
        environment = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_SHA': self.sha}
        with patch.dict(release.os.environ, environment, clear=True), patch.object(release, 'clean_sha', return_value=self.sha), \
                patch.object(release, 'verify_attestations'), \
                patch.object(release, 'api', return_value=[{'ref': 'refs/tags/' + self.tag}]), patch.object(release, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'already exists'):
                release.publish(self.output)
            run.assert_not_called()

    def test_publication_requires_immutable_result_and_never_replaces_assets(self):
        environment = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_SHA': self.sha}
        for immutable in (True, False):
            with self.subTest(immutable=immutable), patch.dict(release.os.environ, environment, clear=True), \
                    patch.object(release, 'clean_sha', return_value=self.sha), patch.object(release, 'verify_attestations'), \
                    patch.object(release, 'api', side_effect=[[], {'immutable': immutable}, {'object': {'sha': self.sha}}]), \
                    patch.object(release, 'run') as run:
                if immutable:
                    release.publish(self.output)
                else:
                    with self.assertRaisesRegex(ValueError, 'not immutable'):
                        release.publish(self.output)
                commands = [call.args[0] for call in run.call_args_list]
                self.assertEqual(commands[0][:3], ['gh', 'release', 'create'])
                self.assertIn('--draft', commands[0])
                self.assertIn('--prerelease', commands[0])
                self.assertEqual(commands[1][:3], ['gh', 'release', 'edit'])
                self.assertFalse(any('--clobber' in command or 'delete' in command for command in commands))



if __name__ == '__main__':
    unittest.main()
