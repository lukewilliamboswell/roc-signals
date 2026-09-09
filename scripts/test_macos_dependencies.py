"""Exercise pinned macOS input admission and deterministic archive construction."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_macos_stubs as producer
import release_dependencies
from dependency_archive import digest
from dependency_artifacts import unpack_verified


class MacOSDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sdk = self.root / 'sdk'
        (self.sdk / 'usr/lib').mkdir(parents=True)
        self.stub = self.sdk / 'usr/lib/libExample.tbd'
        self.stub.write_bytes(b'fixture interface')
        self.license = self.root / 'License.rtf'
        self.license.write_bytes(b'fixture original license')
        self.recipe = {'schema_version': 1, 'name': 'macos-stubs', 'version': 'test',
                       'target': 'macos-sysroot', 'xcode_version': 'test',
                       'xcode_build': 'test', 'sdk_version': 'test', 'sdk_build': 'test',
                       'license_sha256': digest(self.license.read_bytes()),
                       'files': {'usr/lib/libExample.tbd': {
                           'sha256': digest(self.stub.read_bytes()),
                           'install_names': ['/usr/lib/libExample.dylib'], 'reexports': []}}}
        self.recipe_path = self.root / 'recipe.json'
        self.save_recipe()

    def save_recipe(self):
        self.recipe_path.write_text(json.dumps(self.recipe))

    def build(self, name='output'):
        return producer.build(self.sdk, self.license, self.root / name, self.recipe_path)

    def test_reproducible_archive_roundtrip_preserves_exact_inputs(self):
        first, second = self.build('one'), self.build('two')
        self.assertEqual(first.read_bytes(), second.read_bytes())
        destination = self.root / 'extracted'
        manifest = unpack_verified(first, self.recipe, destination)
        self.assertEqual(set(manifest['files']), producer.expected_files(self.recipe))
        producer.validate_contents(destination, self.recipe)
        self.assertEqual((destination / 'targets/macos-sysroot/usr/lib/libExample.tbd').read_bytes(),
                         self.stub.read_bytes())
        with self.assertRaises(FileExistsError):
            self.build('one')
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_tampered_or_missing_input_does_not_create_candidate(self):
        self.stub.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'reviewed pin'):
            self.build()
        self.assertFalse((self.root / 'output').exists())
        self.stub.unlink()
        with self.assertRaises(FileNotFoundError):
            self.build()
        self.assertFalse((self.root / 'output').exists())

    def test_wrong_license_does_not_create_candidate(self):
        self.license.write_bytes(b'different agreement')
        with self.assertRaisesRegex(ValueError, 'agreement differs'):
            self.build()
        self.assertFalse((self.root / 'output').exists())

    def test_reexport_requires_matching_provider_install_name(self):
        self.recipe['files']['usr/lib/libExample.tbd']['reexports'] = ['/usr/lib/libOther.dylib']
        self.save_recipe()
        with self.assertRaisesRegex(ValueError, 'unresolved macOS reexport'):
            self.build()
        self.recipe['files']['usr/lib/libOther.tbd'] = {
            'sha256': '0' * 64, 'install_names': ['/usr/lib/libWrong.dylib'], 'reexports': []}
        self.save_recipe()
        with self.assertRaisesRegex(ValueError, 'unresolved macOS reexport'):
            self.build()
        self.assertFalse((self.root / 'output').exists())

    def test_symlink_cannot_escape_sdk_even_with_matching_bytes(self):
        external = self.root / 'outside.tbd'
        self.stub.rename(external)
        self.stub.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'escapes SDK'):
            self.build()

    def test_extracted_bytes_are_checked_against_reviewed_recipe(self):
        archive = self.build()
        destination = self.root / 'extracted'
        unpack_verified(archive, self.recipe, destination)
        (destination / 'targets/macos-sysroot/usr/lib/libExample.tbd').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'reviewed pin'):
            producer.validate_contents(destination, self.recipe)

    def test_selected_real_recipe_has_closed_reexports(self):
        producer.read_recipe()

    def prepare_release(self, archive):
        notices = self.root / 'macos-stubs'
        notices.mkdir(exist_ok=True)
        (notices / 'NOTICE').write_bytes(producer.NOTICE.read_bytes())
        policy = dict(release_dependencies.KINDS['macos-stubs'], recipe=str(self.recipe_path))
        environment = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_REPOSITORY': release_dependencies.REPOSITORY, 'GITHUB_SHA': 'a' * 40}
        with patch.dict(release_dependencies.KINDS, {'macos-stubs': policy}), patch.object(
                release_dependencies.subprocess, 'check_output', return_value='a' * 40), patch.object(
                release_dependencies, 'verify_archive') as verifier:
            release_dependencies.prepare(archive.parent, 'deps-macos-stubs-1', environment, 'macos-stubs')
        entry = json.loads((archive.parent / 'dependencies.lock.json').read_bytes())['artifacts'][producer.IDENTITY]
        verifier.assert_called_once_with(archive, entry)
        return entry

    def test_release_lock_selects_macos_signing_identity_and_exact_archive(self):
        archive = self.build()
        entry = self.prepare_release(archive)
        self.assertTrue(entry['signer_workflow'].endswith('/.github/workflows/macos-dependencies.yml'))
        self.assertEqual(entry['source_sha'], 'a' * 40)
        self.assertEqual(entry['sha256'], digest(archive.read_bytes()))

    def test_signed_archive_still_requires_reviewed_input_pins(self):
        archive = self.build()
        self.recipe['files']['usr/lib/libExample.tbd']['sha256'] = '0' * 64
        self.save_recipe()
        with self.assertRaisesRegex(ValueError, 'reviewed input pins'):
            self.prepare_release(archive)
        self.assertFalse((archive.parent / 'dependencies.lock.json').exists())


if __name__ == '__main__':
    unittest.main()
