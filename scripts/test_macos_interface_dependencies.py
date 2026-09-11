"""macOS interfaces are deterministic released final-link inputs, not host outputs."""

import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_macos_interfaces as producer
from dependency_artifacts import unpack_verified
import release_dependencies
import prepare_dependencies


class MacosInterfaceDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_generation_is_reproducible_and_contains_no_host_archive_identity(self):
        first = producer.build(self.root / "first")
        second = producer.build(self.root / "second")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        extracted = self.root / "extracted"
        manifest = unpack_verified(first, {"name": producer.NAME, "target": producer.TARGET}, extracted)
        expected = {f"targets/{producer.TARGET}/{name}" for name in producer.interface_files()}
        expected.update(f"targets/{producer.TARGET}/{name}" for name in
                        ("interfaces.json", "manifest.json", "PROVENANCE.md"))
        self.assertEqual(set(manifest["files"]), expected)
        interface_manifest = json.loads((extracted / f"targets/{producer.TARGET}/manifest.json").read_text())
        self.assertNotIn("host_archives_sha256", interface_manifest)

    def test_admission_uses_locked_catalog_and_rejects_inconsistent_release(self):
        # This release intentionally predates the checkout's larger catalog.
        catalog = {"schema_version": 1, "target": "arm64-macos", "libraries": [{
            "name": "libSystem", "path": "usr/lib/libSystem.tbd",
            "install_name": "/usr/lib/libSystem.dylib", "path_sources": ["reviewed source"],
            "symbols": [],
        }]}
        catalog_bytes = json.dumps(catalog).encode()
        names = ("interfaces.json", "manifest.json", "PROVENANCE.md", "usr/lib/libSystem.tbd")
        manifest = {"files": {"targets/macos-sysroot/" + name: {} for name in names},
                    "catalog_sha256": hashlib.sha256(catalog_bytes).hexdigest()}

        def materialize(_lock, identities, _cache, destination):
            self.assertEqual(identities, (producer.IDENTITY,))
            tree = destination / producer.IDENTITY
            target = tree / "targets/macos-sysroot"
            target.mkdir(parents=True)
            (target / "interfaces.json").write_bytes(catalog_bytes)
            (tree / "dependency.json").write_text(json.dumps(manifest))

        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_macos_interfaces() as admitted:
                self.assertTrue(admitted.is_dir())
            manifest["catalog_sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "catalog or inventory"):
                with prepare_dependencies.verified_macos_interfaces():
                    self.fail("inconsistent catalog admitted")
            manifest["catalog_sha256"] = hashlib.sha256(catalog_bytes).hexdigest()
            manifest["files"]["targets/macos-sysroot/unexpected.tbd"] = {}
            with self.assertRaisesRegex(ValueError, "catalog or inventory"):
                with prepare_dependencies.verified_macos_interfaces():
                    self.fail("unexpected interface admitted")

    def test_validation_rejects_mismatched_host_sources_before_download(self):
        import gui_host_artifacts
        import dependency_artifacts
        with patch.object(gui_host_artifacts, "lock_matches_sources", return_value=False), \
                patch.object(dependency_artifacts, "materialize") as download:
            with self.assertRaisesRegex(ValueError, "sources matching"):
                producer.check_candidate(self.root / "candidate.tar", self.root / "lock.json",
                                         "roc", root=self.root)
        download.assert_not_called()

    def test_publication_records_the_independent_signing_workflow(self):
        archive = producer.build(self.root)
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), \
                patch.object(release_dependencies, "verify_archive"):
            release_dependencies.prepare(
                self.root, "deps-macos-interfaces-1", environment, producer.NAME,
            )
        lock = json.loads((self.root / "dependencies.lock.json").read_text())
        entry = lock["artifacts"][producer.IDENTITY]
        self.assertEqual(entry["asset"], archive.name)
        self.assertTrue(entry["signer_workflow"].endswith(
            "/.github/workflows/macos-interface-dependencies.yml"
        ))


if __name__ == "__main__":
    unittest.main()
