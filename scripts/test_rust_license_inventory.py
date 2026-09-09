"""Notice collection must preserve source bytes and reject unverifiable inputs."""

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rust_license_inventory as inventory


class RustLicenseInventoryTests(unittest.TestCase):
    def test_checked_in_notices_match_the_reviewed_hashes_and_locked_crates(self):
        root = Path(__file__).resolve().parents[1]
        directory = root / "dependencies/gui-host-notices"
        manifest = json.loads((directory / "manifest.json").read_text())
        locked = {p["name"] + "@" + p["version"]: p.get("checksum")
                  for p in tomllib.loads((root / "Cargo.lock").read_text())["package"]}
        referenced = set()
        for identity, record in manifest["packages"].items():
            with self.subTest(package=identity):
                self.assertEqual(record["crate_sha256"], locked[identity])
                for notice in record["notices"]:
                    path = directory / notice["path"]
                    self.assertFalse(path.is_symlink())
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), notice["sha256"])
                    self.assertIn("/" + record["source_revision"] + "/", notice["source_url"])
                    referenced.add(path.resolve())
        self.assertEqual(referenced, {p.resolve() for p in (directory / "texts").iterdir()})

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.package = {"name": "example", "version": "1.0.0", "source": inventory.REGISTRY}
        self.about = self.root / "about.json"
        self.about.write_text(json.dumps({"crates": [{"package": self.package}]}))
        self.lock = self.root / "Cargo.lock"

    def archive(self, notice=True, extra=None):
        path = self.root / "example-1.0.0.crate"
        files = {"example-1.0.0/Cargo.toml": b'[package]\nname="example"\nversion="1.0.0"\nlicense="MIT"\n'}
        if notice:
            files["example-1.0.0/LICENSE"] = b"original notice\fwith page separator\n"
        if extra:
            files[extra] = b"invalid path"
        with tarfile.open(path, "w:gz") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        self.lock.write_text(f'[[package]]\nname="example"\nversion="1.0.0"\nsource="{inventory.REGISTRY}"\nchecksum="{checksum}"\n')
        return path, checksum

    def test_preserves_exact_notice_bytes_and_original_declaration(self):
        self.archive()
        output = self.root / "notices"
        result = inventory.collect(self.about, self.lock, self.root, output)
        package = result["packages"][0]
        self.assertEqual(result["missing_notice_files"], [])
        self.assertEqual((output / package["notice_files"]["LICENSE"]["path"]).read_bytes(),
                         b"original notice\fwith page separator\n")
        self.assertEqual(package["declared_license"], "MIT")
        self.assertIn("Cargo.toml", package["declaration_files"])

    def test_license_declaration_does_not_fabricate_a_notice(self):
        self.archive(notice=False)
        result = inventory.collect(self.about, self.lock, self.root, self.root / "notices")
        self.assertEqual(result["missing_notice_files"], ["example@1.0.0"])
        self.assertEqual(result["packages"][0]["notice_files"], {})

    def test_source_retention_preserves_archive_and_does_not_resolve_missing_notice(self):
        archive, checksum = self.archive(notice=False)
        output = self.root / "notices"
        result = inventory.collect(self.about, self.lock, self.root, output, include_sources=True)
        source = result["packages"][0]["source_archive"]
        self.assertEqual((output / source["path"]).read_bytes(), archive.read_bytes())
        self.assertEqual(source["sha256"], checksum)
        self.assertEqual(result["missing_notice_files"], ["example@1.0.0"])

    def test_modified_download_publishes_no_inventory(self):
        archive, _ = self.archive()
        archive.write_bytes(archive.read_bytes() + b"tampered")
        output = self.root / "notices"
        with self.assertRaisesRegex(ValueError, "differs from Cargo.lock"):
            inventory.collect(self.about, self.lock, self.root, output)
        self.assertFalse(output.exists())

    def test_source_changed_after_notice_read_publishes_no_inventory(self):
        archive, _ = self.archive()
        read_notices = inventory.crate_notices

        def changed_archive(*args):
            notices = read_notices(*args)
            archive.write_bytes(archive.read_bytes() + b"changed after verification")
            return notices

        output = self.root / "notices"
        with patch.object(inventory, "crate_notices", side_effect=changed_archive):
            with self.assertRaisesRegex(ValueError, "changed during collection"):
                inventory.collect(self.about, self.lock, self.root, output, include_sources=True)
        self.assertFalse(output.exists())

    def test_archive_path_escape_is_rejected_even_with_valid_checksum(self):
        archive, checksum = self.archive(extra="example-1.0.0/../../escape")
        with self.assertRaisesRegex(ValueError, "unsafe crate archive member"):
            inventory.crate_notices(archive, self.package, checksum)
        self.assertFalse((self.root / "escape").exists())

    def test_unknown_selection_and_existing_output_are_rejected(self):
        self.archive()
        self.about.write_text(json.dumps({"crates": [{"package": dict(self.package, version="2.0.0") }]}))
        output = self.root / "notices"
        with self.assertRaisesRegex(ValueError, "absent from Cargo.lock"):
            inventory.collect(self.about, self.lock, self.root, output)
        self.assertFalse(output.exists())
        output.mkdir()
        with self.assertRaises(FileExistsError):
            inventory.collect(self.about, self.lock, self.root, output)

    def test_upstream_notice_requires_both_crate_hash_and_original_revision(self):
        text = b"actual upstream notice"
        (self.root / "LICENSE").write_bytes(text)
        record = {"crate_sha256": "a" * 64, "source_revision": "b" * 40,
                  "notices": [{"path": "LICENSE", "sha256": hashlib.sha256(text).hexdigest(),
                               "source_url": "https://example.invalid/revision/LICENSE"}]}
        vcs = {"git": {"sha1": "b" * 40}}
        self.assertEqual(inventory.upstream_notices(record, "a" * 64, vcs, self.root), {"LICENSE": text})
        for checksum, revision in (("c" * 64, vcs), ("a" * 64, None),
                                   ("a" * 64, {"git": {"sha1": "c" * 40}})):
            with self.subTest(checksum=checksum, revision=revision):
                with self.assertRaisesRegex(ValueError, "published crate revision"):
                    inventory.upstream_notices(record, checksum, revision, self.root)
        (self.root / "LICENSE").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "reviewed hash"):
            inventory.upstream_notices(record, "a" * 64, vcs, self.root)


if __name__ == "__main__":
    unittest.main()
