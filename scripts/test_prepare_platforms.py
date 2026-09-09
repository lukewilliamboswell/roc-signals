"""Generated platform copies must match the canonical bytes and remain ignored."""
from pathlib import Path
import tempfile
import unittest

from prepare_platforms import check_platform, prepare_platform


class SharedPlatformTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shared = self.root / 'platform-shared'
        self.shared.mkdir()
        (self.shared / 'Signal.roc').write_text('canonical source\n')
        self.package = self.root / 'platform-web'
        self.package.mkdir()
        (self.package / '.gitignore').write_text('/Signal.roc\n')
        (self.package / 'main.roc').write_text('platform entry\n')
        prepare_platform(self.package, self.package)

    def test_matching_copies_pass(self):
        self.assertEqual(check_platform(self.package), [])

    def test_modified_copy_fails_without_repair(self):
        copy = self.package / 'Signal.roc'
        copy.write_text('local drift\n')
        self.assertIn('SHA-256 differs', '\n'.join(check_platform(self.package)))
        self.assertEqual(copy.read_text(), 'local drift\n')

    def test_modified_source_requires_refresh(self):
        (self.shared / 'Signal.roc').write_text('new canonical source\n')
        self.assertIn('SHA-256 differs', '\n'.join(check_platform(self.package)))
        prepare_platform(self.package, self.package)
        self.assertEqual(check_platform(self.package), [])

    def test_missing_copy_fails(self):
        (self.package / 'Signal.roc').unlink()
        self.assertIn('missing shared copy', '\n'.join(check_platform(self.package)))

    def test_missing_ignore_rule_fails(self):
        (self.package / '.gitignore').write_text('')
        self.assertIn('must be gitignored', '\n'.join(check_platform(self.package)))

    def test_removed_source_is_detected(self):
        (self.shared / 'Signal.roc').unlink()
        self.assertIn('no canonical source', '\n'.join(check_platform(self.package)))

    def test_bundle_staging_uses_canonical_source(self):
        (self.package / 'Signal.roc').write_text('stale local copy\n')
        destination = self.root / 'bundle'
        prepare_platform(self.package, destination)
        self.assertEqual((destination / 'Signal.roc').read_bytes(), (self.shared / 'Signal.roc').read_bytes())
        self.assertEqual((destination / 'main.roc').read_text(), 'platform entry\n')
