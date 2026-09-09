"""Keep the diagnostic inventory honest about inputs it cannot classify."""

import struct
import unittest

from audit_windows_archive import audit


def archive(payload):
    header = b"member/         " + b"0           " + b"0     " * 2 + b"0       "
    header += str(len(payload)).encode().ljust(10) + b"`\n"
    return b"!<arch>\n" + header + payload + (b"\n" if len(payload) % 2 else b"")


class WindowsArchiveAuditTests(unittest.TestCase):
    def test_imports_are_reported_without_claiming_final_reachability(self):
        names = b"Example\0EXAMPLE.dll\0"
        payload = struct.pack("<HHHHIIHH", 0, 65535, 0, 0x8664, 0, len(names), 0, 4) + names
        result = audit(archive(payload))
        self.assertEqual(result["dll_import_records"], {"example.dll": 1})
        self.assertEqual(result["members"], {"short_imports": 1})

    def test_directives_are_preserved_and_unknown_members_are_explicit(self):
        directives = b' /DEFAULTLIB:"OLDNAMES" /DEFAULTLIB:"uuid.lib" '
        header = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0, 0)
        section = b".drectve" + b"\0" * 8 + struct.pack("<II", len(directives), 60) + b"\0" * 16
        result = audit(archive(header + section + directives))
        self.assertEqual(result["coff_directives"], {directives.decode().strip(): 1})
        self.assertEqual(audit(archive(b"unrecognized"))["members"], {"other_members": 1})

    def test_truncation_and_thin_archives_are_refused(self):
        for data in (b"!<thin>\n", archive(b"abc")[:-1], archive(b"abc")[:-3]):
            with self.subTest(data=data), self.assertRaises(ValueError):
                audit(data)

    def test_short_import_size_and_coff_section_bounds_are_checked(self):
        malformed = struct.pack("<HHHHIIHH", 0, 65535, 0, 0x8664, 0, 100, 0, 4)
        short_coff = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0, 0)
        for payload in (malformed, short_coff):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                audit(archive(payload))


if __name__ == "__main__":
    unittest.main()
