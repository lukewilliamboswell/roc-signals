"""Generated interfaces require source records and exclude stale SDK payloads."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
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


if __name__ == '__main__':
    unittest.main()
