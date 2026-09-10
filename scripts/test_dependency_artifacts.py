"""Dependency admission rejects untrusted identities and partial archives."""

import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dependency_artifacts as deps
import release_dependencies
from dependency_archive import write_archive


class DependencyTests(unittest.TestCase):
    def test_corresponding_sources_must_belong_to_the_dependency(self):
        for index, name in enumerate(("sources/musl/source.tar.xz", "sources/glibc/source.tar.xz",
                                      "sources/musl-other/source.tar.xz")):
            with self.subTest(name=name):
                archive = write_archive(self.root / f"source-{index}.tar", {
                    "schema_version": 1, "name": "musl", "target": "x64musl",
                }, {name: b"opaque source archive bytes"})
                destination = self.root / f"source-{index}"
                if index == 0:
                    deps.unpack_verified(archive, self.entry, destination)
                    self.assertEqual((destination / name).read_bytes(), b"opaque source archive bytes")
                else:
                    with self.assertRaisesRegex(ValueError, "outside its target, license, or source"):
                        deps.unpack_verified(archive, self.entry, destination)
                    self.assertFalse(destination.exists())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.entry = {
            "name": "musl", "target": "x64musl", "repository": "owner/repo",
            "release": "deps-musl-1", "asset": "musl-x64musl.tar",
            "sha256": "0" * 64, "size": 1, "source_sha": "a" * 40,
            "source_ref": "refs/heads/main",
            "signer_workflow": "owner/repo/.github/workflows/dependencies.yml",
        }

    def archive(self, extra=(), manifest_change=None):
        files = {"targets/x64musl/libc.a": b"libc", "targets/x64musl/crt1.o": b"crt"}
        manifest = {"schema_version": 1, "name": "musl", "target": "x64musl",
                    "files": {name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                              for name, data in files.items()}}
        if manifest_change:
            manifest_change(manifest)
        files["dependency.json"] = json.dumps(manifest).encode()
        archive = self.root / "artifact.tar"
        with tarfile.open(archive, "w") as packed:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                packed.addfile(member, io.BytesIO(data))
            for member in extra:
                packed.addfile(member)
        self.entry.update(sha256=deps.sha256(archive), size=archive.stat().st_size)
        return archive

    def lock(self):
        path = self.root / "lock.json"
        path.write_text(json.dumps({"schema_version": 1, "artifacts": {"musl-x64musl": self.entry}}))
        return path

    def test_archive_verification_uses_reviewed_content_identity_without_network(self):
        archive = self.archive()
        deps.read_lock(self.lock())
        deps.verify_archive(archive, self.entry)

    def test_tampering_is_rejected_before_signature_verification(self):
        archive = self.archive()
        data = bytearray(archive.read_bytes())
        data[600] ^= 1
        archive.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "locked digest"):
            deps.verify_archive(archive, self.entry)

    def test_cached_artifacts_still_require_the_locked_digest(self):
        archive = self.archive()
        cache = self.root / "cache"
        cache.mkdir()
        cached = cache / (self.entry["sha256"] + ".tar")
        archive.rename(cached)
        data = bytearray(cached.read_bytes())
        data[600] ^= 1
        cached.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "locked digest"):
            deps.materialize(self.lock(), ["musl-x64musl"], cache, self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_complete_archive_is_materialized_with_its_lock(self):
        archive = self.archive()
        cache = self.root / "cache"
        cache.mkdir()
        archive.rename(cache / (self.entry["sha256"] + ".tar"))
        deps.materialize(self.lock(), ["musl-x64musl"], cache, self.root / "output")
        output = self.root / "output"
        self.assertEqual((output / "musl-x64musl/targets/x64musl/libc.a").read_bytes(), b"libc")
        self.assertEqual(deps.read_lock(output / "dependencies.lock.json"), deps.read_lock(self.lock()))

    def test_unsafe_duplicate_and_undeclared_members_are_rejected(self):
        for name, kind in [("../escape", tarfile.REGTYPE),
                           ("/escape", tarfile.REGTYPE),
                           ("targets/x64musl/libc.a", tarfile.REGTYPE),
                           ("targets/x64musl/undeclared", tarfile.REGTYPE),
                           ("targets/x64musl/link", tarfile.SYMTYPE),
                           ("targets/x64musl/hardlink", tarfile.LNKTYPE),
                           ("targets/x64musl/fifo", tarfile.FIFOTYPE)]:
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "../../escape"
                archive = self.archive(extra=[member])
                with self.assertRaises(ValueError):
                    deps.unpack_verified(archive, self.entry, self.root / "output")
                self.assertFalse((self.root / "output").exists())

    def test_manifest_identity_inventory_and_member_digests_are_checked(self):
        for change in [lambda m: m.update(target="arm64musl"),
                       lambda m: m.update(name="other"),
                       lambda m: m["files"].pop("targets/x64musl/libc.a"),
                       lambda m: m["files"]["targets/x64musl/libc.a"].update(sha256="0" * 64)]:
            archive = self.archive(manifest_change=change)
            with self.assertRaises(ValueError):
                deps.unpack_verified(archive, self.entry, self.root / "output")
            self.assertFalse((self.root / "output").exists())

    def test_failed_extraction_never_publishes_a_partial_tree(self):
        archive = self.archive()
        with patch.object(deps.shutil, "copyfileobj", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                deps.unpack_verified(archive, self.entry, self.root / "output")
        self.assertFalse((self.root / "output").exists())
        deps.unpack_verified(archive, self.entry, self.root / "output")
        self.assertTrue((self.root / "output/targets/x64musl/crt1.o").is_file())

    def test_lock_rejects_unpinned_or_ambiguous_identity(self):
        for field, value in [("source_ref", "refs/heads/unreviewed"), ("source_sha", "latest"),
                             ("signer_workflow", "elsewhere/repo/.github/workflows/build.yml"),
                             ("release", "../tag"), ("asset", "../file.tar"),
                             ("size", deps.MAX_ARCHIVE_BYTES + 1)]:
            previous = self.entry[field]
            self.entry[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                deps.read_lock(self.lock())
            self.entry[field] = previous

        self.entry["input_fingerprint"] = "not-a-content-hash"
        with self.assertRaisesRegex(ValueError, "input fingerprint"):
            deps.read_lock(self.lock())

    def test_download_limits_and_digest_failures_leave_no_cached_artifact(self):
        archive = self.archive()
        original = archive.read_bytes()
        corrupt = bytearray(original)
        corrupt[600] ^= 1
        for data in (original[:-1], original + b"x", bytes(corrupt)):
            cache = self.root / "cache"
            with patch.object(deps, "urlopen", return_value=io.BytesIO(data)):
                with self.assertRaises(ValueError):
                    deps.fetch(self.entry, cache)
            self.assertEqual(list(cache.iterdir()), [])

    def test_download_closes_temporary_file_before_verification_and_cleanup(self):
        data = self.archive().read_bytes()
        original_temporary = deps.tempfile.NamedTemporaryFile
        opened = []

        def temporary(*args, **kwargs):
            handle = original_temporary(*args, **kwargs)
            opened.append(handle)
            return handle

        def verify(*args):
            self.assertTrue(all(handle.closed for handle in opened))
            raise ValueError("rejected")

        cache = self.root / "closed-cache"
        with patch.object(deps.tempfile, "NamedTemporaryFile", side_effect=temporary), patch.object(
                deps, "urlopen", return_value=io.BytesIO(data)), patch.object(
                deps, "verify_archive", side_effect=verify):
            with self.assertRaisesRegex(ValueError, "rejected"):
                deps.fetch(self.entry, cache)
        self.assertEqual(list(cache.iterdir()), [])

    def test_release_rejects_pr_branch_foreign_repository_and_stale_checkout(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        for field, value in [("GITHUB_EVENT_NAME", "pull_request"),
                             ("GITHUB_REF", "refs/heads/candidate"),
                             ("GITHUB_REPOSITORY", "attacker/fork"),
                             ("GITHUB_SHA", "b" * 40)]:
            with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    release_dependencies.prepare(self.root, "deps-musl-1", dict(environment, **{field: value}))
        self.assertFalse((self.root / "dependencies.lock.json").exists())

    def test_release_requires_both_architectures_before_verification(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        self.archive().rename(self.root / "musl-x64musl.tar")
        with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), patch.object(
                release_dependencies, "verify_archive") as verifier:
            with self.assertRaisesRegex(ValueError, "both tested musl architectures"):
                release_dependencies.prepare(self.root, "deps-musl-1", environment)
            verifier.assert_not_called()


if __name__ == "__main__":
    unittest.main()
