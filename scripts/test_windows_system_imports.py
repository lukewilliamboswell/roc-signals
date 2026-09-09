"""Reject import implementation payloads, incomplete source coverage and unsafe publication."""

import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dependency_archive import write_archive
from release_windows_system_imports import prepare
from windows_system_imports import imports, merge, short_import, source_coverage, validate_helper


def record(symbol='Function', dll='example.dll', flags=4):
    payload = (symbol + '\0' + dll + '\0').encode()
    return struct.pack('<HHHHIIHH', 0, 65535, 0, 0x8664, 0, len(payload), 0, flags) + payload


def archive(body):
    header = f"{'member/':<16}{0:<12}{0:<6}{0:<6}{'644':<8}{len(body):<10}`\n".encode()
    return b'!<arch>\n' + header + body + (b'\n' if len(body) % 2 else b'')


class ImportTests(unittest.TestCase):
    def test_code_and_data_are_distinct_named_imports(self):
        self.assertEqual(short_import(record(flags=5)), ('example.dll', 'Function', 5))
        for flags in (0, 1, 2, 3, 6, 8):
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                short_import(record(flags=flags))

    def test_truncated_extra_foreign_and_unsafe_records_fail(self):
        valid = record()
        for body in (valid[:-1], valid + b'extra', valid[:6] + b'\x4c\x01' + valid[8:], record(dll='../bad.dll'), record(symbol='x\nDATA')):
            with self.assertRaises(ValueError):
                short_import(body)

    def test_import_archive_must_have_only_canonical_descriptors(self):
        with self.assertRaises(ValueError):
            imports(archive(record()), pure=True)
        with self.assertRaises(ValueError):
            validate_helper(b'implementation code', 'example.dll')
        # Extraction from a compiler component deliberately selects only imports;
        # that component itself is never admitted as a distributable stub archive.
        self.assertEqual(imports(archive(b'implementation code')), {})

    def test_descriptor_rejects_executable_and_hidden_section_payloads(self):
        header = struct.pack('<HHIIIHH', 0x8664, 1, 0, 80, 1, 0, 0)
        section = struct.pack('<8sIIIIIIHHI', b'.idata$3', 0, 0, 20, 60, 0, 0, 0, 0, 0xC0300040)
        valid = header + section + bytes(20) + bytes(18) + struct.pack('<I', 4)
        self.assertEqual(validate_helper(valid, 'example.dll'), (b'.idata$3',))
        bad = bytearray(valid)
        struct.pack_into('<I', bad, 56, 0xE0300060)
        with self.assertRaises(ValueError):
            validate_helper(bytes(bad), 'example.dll')
        bad = bytearray(valid)
        bad[60] = 1
        with self.assertRaises(ValueError):
            validate_helper(bytes(bad), 'example.dll')
        bad = bytearray(valid)
        struct.pack_into('<I', bad, 40, 0)
        with self.assertRaises(ValueError):
            validate_helper(bytes(bad), 'example.dll')

    def test_conflicting_symbol_types_cannot_be_merged(self):
        destination = {'example.dll': {'Function': 4}}
        with self.assertRaises(ValueError):
            merge(destination, {'example.dll': {'Function': 5}})

    def test_source_coverage_handles_aliases_and_only_explicit_x86_exclusion(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            file = source / 'mod.rs'
            file.write_text('''#[inline]
pub unsafe fn Function() {
    windows_link::link!("example.dll" "system" "RealFunction" fn Function());
}
#[cfg(target_arch = "x86")]
#[inline]
pub unsafe fn X86Function() {
    windows_link::link!("example.dll" "system" fn X86Function());
}
''')
            result = source_coverage(source, {'example.dll': {'RealFunction': 4}})
            self.assertEqual(len(result['resolved_aliases']), 1)
            self.assertEqual(len(result['x86_only']), 1)
            file.write_text(file.read_text().replace('target_arch = "x86"', 'feature = "AnotherFeature"'))
            with self.assertRaises(ValueError):
                source_coverage(source, {'example.dll': {'RealFunction': 4}})

    def test_unknown_link_macro_syntax_cannot_hide_a_declaration(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / 'mod.rs').write_text('windows_link::link!(NEW_FORMAT);')
            with self.assertRaises(ValueError):
                source_coverage(source, {})


class PublicationTests(unittest.TestCase):
    def test_non_main_publication_is_refused_before_any_external_call(self):
        with self.assertRaises(ValueError):
            prepare(Path('/missing'), 'deps-windows-system-imports-1', {})

    def test_incomplete_payload_is_refused(self):
        sha = '1' * 40
        environment = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_REPOSITORY': 'lukewilliamboswell/roc-signals', 'GITHUB_SHA': sha}
        with tempfile.TemporaryDirectory() as temporary, patch('release_windows_system_imports.subprocess.check_output', return_value=sha):
            root = Path(temporary)
            write_archive(root / 'windows-system-imports-x64mingw.tar',
                          {'schema_version': 1, 'name': 'windows-system-imports', 'version': '1', 'target': 'x64mingw', 'source': {}},
                          {'targets/x64mingw/one.lib': b'not a complete package'})
            with self.assertRaisesRegex(ValueError, 'inventory'):
                prepare(root, 'deps-windows-system-imports-1', environment)
            self.assertFalse((root / 'dependencies.lock.json').exists())


if __name__ == '__main__':
    unittest.main()
