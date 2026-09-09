"""Reject drift in Windows import definitions and preserve artifact identities."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_windows_imports as producer
import release_dependencies
from dependency_archive import digest


class WindowsDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "lib/libc/mingw"
        self.source.mkdir(parents=True)
        self.definition = self.source / "advapi32.def"
        self.definition.write_bytes(b"definition")
        (self.source / "COPYING").write_bytes(b"license")
        recipe = {"schema_version": 1, "name": "windows-imports", "version": "test",
                  "target": "x64win", "zig_version": "0.16.0", "libraries": ["advapi32"],
                  "source_files_sha256": {name: digest((self.source / name).read_bytes())
                                          for name in ("advapi32.def", "COPYING")}}
        self.recipe = self.root / "recipe.json"
        self.recipe.write_text(json.dumps(recipe))

    def generate(self, name, directory):
        (directory / (name + ".lib")).write_bytes(b"generated import")

    def build(self, directory):
        with patch.object(producer, "RECIPE", self.recipe), patch.object(
                producer.subprocess, "check_output", return_value="0.16.0"), patch.object(
                producer.windows_imports, "zig_lib_dir", return_value=self.root / "lib"), patch.object(
                producer.windows_imports, "windows_import_library", side_effect=self.generate):
            return producer.build(directory)

    def test_changed_definition_is_rejected_before_any_artifact_is_created(self):
        self.definition.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "reviewed pin"):
            self.build(self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_archive_is_reproducible_and_existing_identity_is_not_replaced(self):
        first = self.build(self.root / "one")
        second = self.build(self.root / "two")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with self.assertRaises(FileExistsError):
            self.build(first.parent)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(list(first.parent.iterdir()), [first])

    def test_windows_release_lock_requires_the_windows_signing_workflow(self):
        archive = self.build(self.root / "release")
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), patch.object(
                release_dependencies, "verify_archive") as verifier:
            release_dependencies.prepare(archive.parent, "deps-windows-imports-1", environment, "windows-imports")
        entry = json.loads((archive.parent / "dependencies.lock.json").read_text())["artifacts"]["windows-imports-x64win"]
        self.assertTrue(entry["signer_workflow"].endswith("/.github/workflows/windows-dependencies.yml"))
        self.assertEqual(entry["source_sha"], "a" * 40)
        self.assertEqual(entry["sha256"], digest(archive.read_bytes()))
        verifier.assert_called_once_with(archive, entry)


if __name__ == "__main__":
    unittest.main()
