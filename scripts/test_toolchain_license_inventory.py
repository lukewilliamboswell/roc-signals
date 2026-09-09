"""Runtime notices require original, hash-verified distribution inputs."""

import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import toolchain_license_inventory as inventory


class ToolchainNoticeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def archive(self, filename, members):
        path = self.root / filename
        with tarfile.open(path, "w:xz") as archive:
            for name, data in members:
                member = tarfile.TarInfo("distribution/" + name)
                if data is None:
                    member.type = tarfile.SYMTYPE
                    member.linkname = "LICENSE"
                    archive.addfile(member)
                else:
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
        recipe = {"prefix": "distribution", "notices": ["LICENSE"],
                  "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "source_url": "https://example.invalid/" + filename}
        return path, recipe

    def test_rejects_tampered_missing_duplicate_and_symlinked_notices(self):
        for members in ([], [("LICENSE", b"one"), ("LICENSE", b"two")], [("LICENSE", None)]):
            with self.subTest(members=members):
                archive, recipe = self.archive("bad.tar.xz", members)
                with self.assertRaises(ValueError):
                    inventory.distribution_notices(archive, recipe)
        archive, recipe = self.archive("good.tar.xz", [("LICENSE", b"original\fnotice")])
        self.assertEqual(inventory.distribution_notices(archive, recipe), {"LICENSE": b"original\fnotice"})
        archive.write_bytes(archive.read_bytes() + b"tamper")
        with self.assertRaisesRegex(ValueError, "pinned hash"):
            inventory.distribution_notices(archive, recipe)

    def test_preserves_source_and_runtime_notices_atomically(self):
        rust, rust_recipe = self.archive("rust.tar.xz", [("LICENSE", b"Rust runtime notice")])
        zig, zig_recipe = self.archive("zig.tar.xz", [("LICENSE", b"Zig notice"),
                                                    ("lib/std/example.zig", b"original source copyright")])
        recipe = self.root / "recipe.json"
        recipe.write_text(json.dumps({"schema_version": 1,
                                      "rust": {"version": "1", "targets": {"x64glibc": rust_recipe}},
                                      "zig": dict(zig_recipe, version="2")}))
        output = self.root / "notices"
        result = inventory.collect(recipe, "x64glibc", rust, zig, output)
        self.assertEqual((output / "sources/zig-2.tar.xz").read_bytes(), zig.read_bytes())
        self.assertEqual((output / "notices/rust/LICENSE").read_bytes(), b"Rust runtime notice")
        for path, record in result["files"].items():
            data = (output / path).read_bytes()
            self.assertEqual(record, {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
        with self.assertRaises(FileExistsError):
            inventory.collect(recipe, "x64glibc", rust, zig, output)
        zig.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "pinned hash"):
            inventory.collect(recipe, "x64glibc", rust, zig, self.root / "refused")
        self.assertFalse((self.root / "refused").exists())

    def test_recipe_cannot_write_outside_inventory(self):
        recipe = self.root / "recipe.json"
        recipe.write_text(json.dumps({"schema_version": 1, "rust": {"version": "1"},
                                      "zig": {"version": "../../escape"}}))
        with self.assertRaisesRegex(ValueError, "unsafe toolchain version"):
            inventory.collect(recipe, "x64glibc", self.root / "unused", self.root / "unused",
                              self.root / "output")
        self.assertFalse((self.root / "output").exists())


if __name__ == "__main__":
    unittest.main()
