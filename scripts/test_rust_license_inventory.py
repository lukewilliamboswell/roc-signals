"""Notice collection must preserve source bytes and reject unverifiable inputs."""

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rust_license_inventory as inventory


class RustLicenseInventoryTests(unittest.TestCase):
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

    def test_modified_download_publishes_no_inventory(self):
        archive, _ = self.archive()
        archive.write_bytes(archive.read_bytes() + b"tampered")
        output = self.root / "notices"
        with self.assertRaisesRegex(ValueError, "differs from Cargo.lock"):
            inventory.collect(self.about, self.lock, self.root, output)
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


if __name__ == "__main__":
    unittest.main()
