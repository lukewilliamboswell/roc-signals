"""Reject unreviewed compiler bytes before glibc dependency generation."""

import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_glibc
import release_dependencies
from dependency_archive import digest, write_archive


class GlibcDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = b"reviewed compiler distribution"
        self.source = {"url": "https://example.invalid/toolchain.tar.xz", "size": len(self.data),
                       "sha256": digest(self.data)}

    def test_cache_hits_are_verified_without_network_access(self):
        path = self.root / (self.source["sha256"] + ".tar.xz")
        path.write_bytes(self.data)
        with patch.object(build_glibc, "urlopen") as download:
            self.assertEqual(build_glibc.verified_toolchain(self.source, self.root), path)
            path.write_bytes(b"x" * len(self.data))
            with self.assertRaisesRegex(ValueError, "reviewed pin"):
                build_glibc.verified_toolchain(self.source, self.root)
        download.assert_not_called()

    def test_download_size_and_hash_failures_publish_no_cache_entry(self):
        for data in (self.data[:-1], self.data + b"extra", b"x" * len(self.data)):
            with self.subTest(data=data), patch.object(build_glibc, "urlopen", return_value=io.BytesIO(data)):
                with self.assertRaises(ValueError):
                    build_glibc.verified_toolchain(self.source, self.root)
                self.assertEqual(list(self.root.iterdir()), [])

    def test_symlinked_compiler_cache_is_rejected(self):
        source = self.root / "other"
        source.write_bytes(self.data)
        (self.root / (self.source["sha256"] + ".tar.xz")).symlink_to(source)
        with self.assertRaisesRegex(ValueError, "reviewed pin"):
            build_glibc.verified_toolchain(self.source, self.root)

    def test_existing_candidate_is_not_rebuilt_or_overwritten(self):
        candidate = self.root / "glibc-x64glibc.tar"
        candidate.write_bytes(b"original tested bytes")
        with patch.object(build_glibc, "verified_toolchain") as download:
            with self.assertRaises(FileExistsError):
                build_glibc.build(self.root, self.root / "cache")
        download.assert_not_called()
        self.assertEqual(candidate.read_bytes(), b"original tested bytes")

    def test_publication_requires_sources_and_records_the_glibc_signer(self):
        policy = release_dependencies.KINDS["glibc"]
        files = {"targets/x64glibc/" + name: b"generated input" for name in policy["files"]}
        files.update({"licenses/glibc/" + name: b"notice" for name in policy["licenses"]})
        files.update({name: b"corresponding source" for name in policy["extra_files"]})
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        for missing in (None, "sources/glibc/source.tar.xz", "licenses/glibc/COPYING.LIB"):
            with self.subTest(missing=missing):
                directory = self.root / ("complete" if missing is None else Path(missing).name)
                payload = {name: data for name, data in files.items() if name != missing}
                write_archive(directory / "glibc-x64glibc.tar", {
                    "schema_version": 1, "name": "glibc", "target": "x64glibc", "version": "test",
                }, payload)
                with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), patch.object(
                        release_dependencies, "verify_archive"):
                    if missing:
                        with self.assertRaisesRegex(ValueError, "incomplete or unexpected"):
                            release_dependencies.prepare(directory, "deps-glibc-1", environment, "glibc")
                        self.assertFalse((directory / "dependencies.lock.json").exists())
                    else:
                        release_dependencies.prepare(directory, "deps-glibc-1", environment, "glibc")
                        lock = json.loads((directory / "dependencies.lock.json").read_text())
                        self.assertTrue(lock["artifacts"]["glibc-x64glibc"]["signer_workflow"].endswith(
                            "/.github/workflows/glibc-dependencies.yml"))


if __name__ == "__main__":
    unittest.main()
