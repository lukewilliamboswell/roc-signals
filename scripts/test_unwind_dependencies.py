"""Reject unreviewed compiler bytes before unwind dependency generation."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_unwind
import release_dependencies
from dependency_archive import write_archive


class UnwindDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
    def test_existing_candidate_is_not_rebuilt_or_overwritten(self):
        candidate = self.root / "unwind-x64glibc.tar"
        candidate.write_bytes(b"original tested bytes")
        with patch.object(build_unwind, "verified_toolchain") as download:
            with self.assertRaises(FileExistsError):
                build_unwind.build(self.root, self.root / "cache")
        download.assert_not_called()
        self.assertEqual(candidate.read_bytes(), b"original tested bytes")

    def test_publication_requires_sources_and_records_the_unwind_signer(self):
        policy = release_dependencies.KINDS["unwind"]
        files = {"targets/x64glibc/" + name: b"generated input" for name in policy["files"]}
        files.update({"licenses/unwind/" + name: b"notice" for name in policy["licenses"]})
        files.update({name: b"corresponding source" for name in policy["extra_files"]})
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        for missing in (None, "sources/unwind/source.tar.xz", "licenses/unwind/LICENSE.TXT", "unexpected-library"):
            with self.subTest(missing=missing):
                directory = self.root / ("complete" if missing is None else Path(missing).name)
                payload = {name: data for name, data in files.items() if name != missing}
                if missing == "unexpected-library":
                    payload["targets/x64glibc/libc++abi.a"] = b"private probe support"
                write_archive(directory / "unwind-x64glibc.tar", {
                    "schema_version": 1, "name": "unwind", "target": "x64glibc", "version": "test",
                }, payload)
                with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), patch.object(
                        release_dependencies, "verify_archive"):
                    if missing:
                        with self.assertRaisesRegex(ValueError, "incomplete or unexpected"):
                            release_dependencies.prepare(directory, "deps-unwind-1", environment, "unwind")
                        self.assertFalse((directory / "dependencies.lock.json").exists())
                    else:
                        release_dependencies.prepare(directory, "deps-unwind-1", environment, "unwind")
                        lock = json.loads((directory / "dependencies.lock.json").read_text())
                        self.assertTrue(lock["artifacts"]["unwind-x64glibc"]["signer_workflow"].endswith(
                            "/.github/workflows/unwind-dependencies.yml"))


if __name__ == "__main__":
    unittest.main()
