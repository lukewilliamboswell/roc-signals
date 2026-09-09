"""Source identity and publication failures must not admit substitute FreeType bytes."""

import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_freetype as producer
from dependency_archive import digest, write_archive
import release_dependencies


class FreeTypeDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bytes = b"reviewed source bytes"
        self.source = {"url": "https://example.invalid/source.tar.xz",
                       "size": len(self.bytes), "sha256": digest(self.bytes)}

    def test_source_cache_is_verified_on_every_use(self):
        with patch.object(producer, "urlopen", return_value=io.BytesIO(self.bytes)):
            source = producer.fetch_source(self.source, self.root / "cache")
        with patch.object(producer, "urlopen") as network:
            self.assertEqual(producer.fetch_source(self.source, source.parent), source)
            network.assert_not_called()
            source.write_bytes(b"changed source bytes!")
            with self.assertRaisesRegex(ValueError, "reviewed recipe"):
                producer.fetch_source(self.source, source.parent)
            network.assert_not_called()

    def test_incomplete_oversized_and_wrong_digest_sources_are_not_cached(self):
        for index, data in enumerate((self.bytes[:-1], self.bytes + b"x", b"x" * len(self.bytes))):
            with self.subTest(index=index):
                cache = self.root / str(index)
                with patch.object(producer, "urlopen", return_value=io.BytesIO(data)):
                    with self.assertRaises(ValueError):
                        producer.fetch_source(self.source, cache)
                self.assertEqual(list(cache.iterdir()), [])

    def make_archive(self, missing_license=False):
        policy = release_dependencies.KINDS["freetype"]
        files = {"targets/x64glibc/libfreetype.so": b"tested shared library"}
        for name in policy["licenses"]:
            files["licenses/freetype/" + name] = b"license text"
        if missing_license:
            del files["licenses/freetype/NOTICE"]
        return write_archive(self.root / producer.ARCHIVE_NAME,
                             {"schema_version": 1, "name": "freetype", "version": "test",
                              "target": "x64glibc"}, files)

    def prepare(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), patch.object(
                release_dependencies, "verify_archive") as verifier:
            release_dependencies.prepare(self.root, "deps-freetype-1", environment, "freetype")
        return verifier

    def test_release_lock_binds_the_freetype_producer(self):
        archive = self.make_archive()
        verifier = self.prepare()
        lock = json.loads((self.root / "dependencies.lock.json").read_text())
        entry = lock["artifacts"]["freetype-x64glibc"]
        self.assertTrue(entry["signer_workflow"].endswith("/.github/workflows/freetype-dependencies.yml"))
        self.assertEqual(entry["sha256"], digest(archive.read_bytes()))
        verifier.assert_called_once_with(archive, entry)

    def test_missing_license_refuses_publication(self):
        self.make_archive(missing_license=True)
        with self.assertRaisesRegex(ValueError, "incomplete or unexpected"):
            self.prepare()
        self.assertFalse((self.root / "dependencies.lock.json").exists())


if __name__ == "__main__":
    unittest.main()
