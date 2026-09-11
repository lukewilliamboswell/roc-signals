"""macOS interfaces are deterministic released final-link inputs, not host outputs."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_macos_interfaces as producer
from dependency_artifacts import unpack_verified
import release_dependencies


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
