"""Generated interfaces require source records and exclude stale SDK payloads."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import shutil
import subprocess
from types import SimpleNamespace
import urllib.request
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_macos_stubs as stubs
import bundle_platforms


class MacosInterfacesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archives = self.root / 'archives'
        self.archives.mkdir()
        for name in stubs.ARCHIVES:
            (self.archives / name).write_bytes(name.encode())
        self.catalog = {
            'schema_version': 1, 'target': 'arm64-macos',
            'libraries': [{'name': 'libSystem', 'path': 'usr/lib/libSystem.tbd',
                           'install_name': '/usr/lib/libSystem.dylib',
                           'path_sources': ['https://example.org/library'],
                           'symbols': [{'name': '_malloc', 'sources': ['https://example.org/malloc']}]}],
        }
        self.catalog_path = self.root / 'catalog.json'
        self.write_catalog(self.catalog)

    def write_catalog(self, catalog):
        self.catalog_path.write_text(json.dumps(catalog))

    def test_generation_is_deterministic_and_binds_archive_bytes(self):
        first = stubs.generate(self.archives, self.root / 'first', self.catalog_path)
        second = stubs.generate(self.archives, self.root / 'second', self.catalog_path)
        self.assertEqual(first, second)
        for relative, expected in first['files_sha256'].items():
            contents = (self.root / 'first' / relative).read_bytes()
            self.assertEqual(hashlib.sha256(contents).hexdigest(), expected)
            self.assertEqual(contents, (self.root / 'second' / relative).read_bytes())
        (self.archives / stubs.ARCHIVES[0]).write_bytes(b'changed host')
        third = stubs.generate(self.archives, self.root / 'third', self.catalog_path)
        self.assertNotEqual(first['host_archives_sha256'], third['host_archives_sha256'])

    def test_missing_evidence_and_unsafe_paths_are_rejected_before_output(self):
        for field, value in [('path', '../escape.tbd'), ('path', '/escape.tbd'),
                             ('path_sources', []), ('install_name', "/usr/lib/a'\nb")]:
            with self.subTest(field=field, value=value):
                catalog = copy.deepcopy(self.catalog)
                catalog['libraries'][0][field] = value
                self.write_catalog(catalog)
                with self.assertRaises(ValueError):
                    stubs.generate(self.archives, self.root / 'rejected', self.catalog_path)
                self.assertFalse((self.root / 'rejected').exists())
        self.catalog['libraries'][0]['symbols'][0]['sources'] = []
        self.write_catalog(self.catalog)
        with self.assertRaisesRegex(ValueError, 'source evidence'):
            stubs.generate(self.archives, self.root / 'rejected', self.catalog_path)

    def test_bundle_regenerates_instead_of_copying_stale_interfaces(self):
        stale = self.root / 'macos-sysroot'
        stale.mkdir()
        (stale / 'SDK-only.tbd').write_text('old SDK payload')
        def generate(archives, destination):
            return stubs.generate(archives, destination, self.catalog_path)
        with patch.object(bundle_platforms, 'generate_macos_interfaces', side_effect=generate):
            bundle_platforms.stage_macos_inputs(self.archives, self.root / 'stage')
        staged = self.root / 'stage/targets/macos-sysroot'
        self.assertFalse((staged / 'SDK-only.tbd').exists())
        self.assertTrue((staged / 'usr/lib/libSystem.tbd').is_file())
        self.assertEqual(json.loads((staged / 'manifest.json').read_text())['origin'],
                         'project-generated-macos-interfaces')


    def test_http_check_consumes_archive_with_fresh_cache_for_every_example(self):
        import check_macos_interfaces as check
        import gui_suite
        import spec_driver
        import toolchain
        output = self.root / 'served'
        output.mkdir()
        (output / 'bundles.json').write_text(json.dumps({'gui': 'candidate.tar.zst'}))
        (output / 'candidate.tar.zst').write_bytes(b'actual served bytes')
        calls = []
        def build(command, **kwargs):
            source = Path(command[-1])
            text = source.read_text()
            span = toolchain.app_platform_span(text)
            url = text[slice(*span)]
            self.assertTrue(url.startswith('http://127.0.0.1:'))
            with urllib.request.urlopen(url) as response:
                self.assertEqual(response.read(), b'actual served bytes')
            self.assertIn('--target=arm64mac', command)
            self.assertIn('--no-cache', command)
            self.assertFalse(Path(kwargs['env']['ROC_CACHE_DIR']).exists())
            calls.append(source.parent.name)
        with patch.object(check.platform, 'system', return_value='Darwin'), \
             patch.object(check.platform, 'machine', return_value='arm64'), \
             patch.object(toolchain, 'verify_compiler'), \
             patch.object(check.subprocess, 'run', side_effect=build), \
             patch.object(spec_driver, 'run_suite', return_value=[SimpleNamespace(passed=True)]), \
             patch.object(spec_driver, 'print_summary'):
            result = check.check_bundle(output, 'roc')
        self.assertEqual(calls, [app.name for app in gui_suite.examples()])
        self.assertEqual(len(result['examples']), 6)

    def test_compatibility_proof_rejects_input_drift(self):
        import check_macos_interfaces as check
        stage = self.root / 'platform'
        shutil.copytree(self.archives, stage / 'targets/arm64mac')
        directory = stage / 'targets/macos-sysroot'
        manifest = stubs.generate(stage / 'targets/arm64mac', directory, self.catalog_path)
        for relative in ('interfaces.json', 'PROVENANCE.md', 'usr/lib/libSystem.tbd'):
            with self.subTest(input=relative):
                path = directory / relative
                original = path.read_bytes()
                def mutate(*args, **kwargs):
                    path.write_bytes(original + b'changed')
                    return {'compiler_pin': 'pin', 'examples': {'counter': 1}}
                with patch.object(check, 'check_apps', side_effect=mutate):
                    with self.assertRaisesRegex(ValueError, 'changed during'):
                        check.validate_platform(stage, 'roc')
                self.assertFalse((directory / 'validation.json').exists())
                path.write_bytes(original)
        with patch.object(check, 'check_apps', return_value={'compiler_pin': 'pin', 'examples': {'counter': 1}}):
            check.validate_platform(stage, 'roc')
        proof = json.loads((directory / 'validation.json').read_text())
        self.assertEqual(proof['interface_manifest_sha256'], hashlib.sha256((directory / 'manifest.json').read_bytes()).hexdigest())
        self.assertEqual(manifest['host_archives_sha256'], json.loads((directory / 'manifest.json').read_text())['host_archives_sha256'])

    def test_committed_catalog_has_reviewed_provider_structure(self):
        catalog = stubs.read_catalog()
        self.assertEqual(len(catalog['libraries']), 19)
        self.assertEqual(sum(len(library['symbols']) for library in catalog['libraries']), 406)
        for library in catalog['libraries']:
            if library['name'].startswith('lib'):
                self.assertEqual(library['path'], 'usr/lib/' + library['name'] + '.tbd')
                self.assertEqual(library['install_name'], {'libSystem': '/usr/lib/libSystem.dylib',
                                 'libobjc': '/usr/lib/libobjc.A.dylib', 'libc++': '/usr/lib/libc++.1.dylib'}[library['name']])
            else:
                base = 'System/Library/Frameworks/' + library['name'] + '.framework/' + library['name']
                self.assertEqual(library['path'], base + '.tbd')
                self.assertEqual(library['install_name'], '/' + base)
        carbon = next(l for l in catalog['libraries'] if l['name'] == 'Carbon')
        key = next(s for s in carbon['symbols'] if s['name'] == '_UCKeyTranslate')
        self.assertTrue(any(s.get('framework') == 'Carbon' and s.get('provider_line') == 1549 for s in key['sources']))
        system = next(l for l in catalog['libraries'] if l['name'] == 'libSystem')
        system_symbols = {symbol['name'] for symbol in system['symbols']}
        self.assertTrue({'_acos', '_lstat', '_pthread_cond_broadcast'} <= system_symbols)

    def test_complete_bundler_excludes_stale_sdk_and_requires_compatibility(self):
        root = self.root / 'repo'
        original = bundle_platforms.ROOT
        for directory in ('platform-gui', 'platform-shared', 'examples-gui', 'vendor', 'crates/gpui-host'):
            (root / directory).mkdir(parents=True, exist_ok=True)
        for directory in ('platform-gui', 'platform-shared'):
            for path in (original / directory).glob('*.roc'):
                shutil.copyfile(path, root / directory / path.name)
        shutil.copyfile(original / 'platform-gui/.gitignore', root / 'platform-gui/.gitignore')
        shutil.copyfile(original / 'crates/gpui-host/LICENSE-GPUI', root / 'crates/gpui-host/LICENSE-GPUI')
        host = root / 'platform-gui/targets/arm64mac'
        shutil.copytree(self.archives, host)
        stale = root / 'platform-gui/targets/macos-sysroot/SDK-only.tbd'
        stale.parent.mkdir()
        stale.write_text('STALE SDK BYTES')
        (host / 'SDK-only.tbd').write_text('STALE SDK BYTES')
        output = self.root / 'bundles'
        admitted = []
        def bundle(command, **kwargs):
            self.assertEqual(command[1], 'bundle')
            stage = Path(kwargs['cwd'])
            self.assertFalse(any('SDK-only' in p.name for p in stage.rglob('*')))
            self.assertTrue((stage / 'targets/macos-sysroot/manifest.json').is_file())
            admitted.append(True)
            archive = output / 'candidate.tar.zst'
            archive.write_bytes(b'fixture')
            return subprocess.CompletedProcess(command, 0, stdout='Created: ' + str(archive) + '\n')
        import check_macos_interfaces
        with patch.object(bundle_platforms, 'ROOT', root), patch.object(bundle_platforms, 'gui_examples', return_value=()), \
             patch.object(bundle_platforms, 'stage_example_package'), \
             patch.object(bundle_platforms.subprocess, 'run', side_effect=bundle), \
             patch.object(check_macos_interfaces, 'validate_platform') as validate, \
             patch.object(sys, 'argv', ['bundle', '--package', 'gui', '--no-build', '--output-dir', str(output)]):
            (root / 'examples-gui/counter').mkdir()
            shutil.copyfile(original / 'examples-gui/counter/main.roc', root / 'examples-gui/counter/main.roc')
            bundle_platforms.main()
            validate.assert_called_once()
            self.assertEqual(admitted, [True])
            validate.side_effect = ValueError('changed host fails final link')
            with self.assertRaisesRegex(ValueError, 'changed host'):
                bundle_platforms.main()
            self.assertEqual(admitted, [True])


if __name__ == '__main__':
    unittest.main()
