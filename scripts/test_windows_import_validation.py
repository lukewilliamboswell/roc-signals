"""Exercise admission with real dlltool output and deliberately damaged stubs."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from windows_import_validation import validate_import_library


class WindowsImportValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.definition = 'LIBRARY "TEST.dll"\nEXPORTS\nFirst\nSecond @123\n'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "test.def"
            source.write_text(cls.definition)
            output = root / "test.lib"
            subprocess.run(["zig", "dlltool", "-m", "i386:x86-64", "-d", str(source), "-l", str(output)], check=True)
            cls.library = output.read_bytes()

    def test_real_complete_import_library(self):
        self.assertEqual(validate_import_library(self.library, self.definition), 2)

    def test_host_specific_subset_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "complete DLL definition"):
            validate_import_library(self.library, self.definition + "Third\n")

    def test_unexpected_export_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "complete DLL definition"):
            validate_import_library(self.library, self.definition.replace("First\n", ""))

    def test_wrong_hint_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "complete DLL definition"):
            validate_import_library(self.library, self.definition.replace("@123", "@124"))

    def test_foreign_dll_is_rejected(self):
        # Change only a short import's DLL field, preserving descriptors/indexes.
        damaged = self.library.replace(b"First\0TEST.dll\0", b"First\0EVIL.dll\0")
        self.assertNotEqual(damaged, self.library)
        with self.assertRaisesRegex(ValueError, "foreign DLL"):
            validate_import_library(damaged, self.definition)

    def test_implementation_section_is_rejected(self):
        damaged = self.library.replace(b".idata$2", b".text\0\0\0")
        self.assertNotEqual(damaged, self.library)
        with self.assertRaisesRegex(ValueError, "implementation section"):
            validate_import_library(damaged, self.definition)

    def test_nonzero_helper_payload_is_rejected(self):
        damaged = bytearray(self.library)
        section = damaged.index(b".idata$3")
        # The section table immediately follows the 20-byte COFF header.
        object_start = section - 20
        payload_offset = int.from_bytes(damaged[section + 20:section + 24], "little")
        damaged[object_start + payload_offset] = 0x90
        with self.assertRaisesRegex(ValueError, "section payload"):
            validate_import_library(bytes(damaged), self.definition)

    def test_truncation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "truncated"):
            validate_import_library(self.library[:-1], self.definition)

    def test_new_definition_syntax_requires_review(self):
        with self.assertRaisesRegex(ValueError, "unsupported Windows export syntax"):
            validate_import_library(self.library, self.definition + "Third DATA\n")


if __name__ == "__main__":
    unittest.main()
