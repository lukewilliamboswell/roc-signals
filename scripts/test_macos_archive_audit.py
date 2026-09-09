"""Keep archive inventories complete and avoid labeling internal calls imports."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_macos_archive import audit, parse_symbols


class MacOSArchiveAuditTests(unittest.TestCase):
    def test_members_and_exact_symbol_spelling_are_retained(self):
        references, definitions, kinds = parse_symbols(
            'host.a[first.o]: _OBJC_CLASS_$_NSObject U 0 0\n'
            'host.a[second.o]: _OBJC_CLASS_$_NSObject U 0 0\n'
            'host.a[first.o]: _optional w 0 0\n'
            'host.a[first.o]: _provided W ---------------- 0\n', Path('host.a'))
        self.assertEqual(references['_OBJC_CLASS_$_NSObject'], {'first.o', 'second.o'})
        self.assertIn('_optional', references)
        self.assertEqual(definitions, {'_provided'})
        self.assertEqual(kinds, {'U': 2, 'W': 1, 'w': 1})

    def test_unknown_records_fail_instead_of_disappearing(self):
        for line in ('host.a[x.o]: _unknown ? 0 0', 'unexpected heading',
                     'other.a[x.o]: _wrong U 0 0'):
            with self.subTest(line=line), self.assertRaises(ValueError):
                parse_symbols(line, Path('host.a'))

    def test_definitions_in_any_supplied_archive_resolve_references(self):
        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary) / 'host.a'
            engine = Path(temporary) / 'engine.a'
            host.write_bytes(b'host fixture')
            engine.write_bytes(b'engine fixture')
            outputs = [subprocess.CompletedProcess([], 0,
                       f'{host}[host.o]: _engine U 0 0\n{host}[host.o]: _malloc U 0 0\n', ''),
                       subprocess.CompletedProcess([], 0, f'{engine}[engine.o]: _engine T 0 0\n', '')]
            with patch('audit_macos_archive.subprocess.check_output', return_value='LLVM fixture'), patch(
                    'audit_macos_archive.subprocess.run', side_effect=outputs):
                result = audit([host, engine], Path('llvm-nm'))
            self.assertEqual(result['external_symbol_count'], 1)
            self.assertEqual(result['external_symbols'], [
                {'name': '_malloc', 'references': [{'archive': 0, 'member': 'host.o'}]}])
            self.assertNotEqual(result['archives'][0]['sha256'], result['archives'][1]['sha256'])

    def test_incompatible_reader_cannot_publish_partial_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'host.a'
            archive.write_bytes(b'fixture')
            with patch('audit_macos_archive.subprocess.check_output', return_value='old LLVM'), patch(
                    'audit_macos_archive.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'llvm-nm')):
                with self.assertRaises(subprocess.CalledProcessError):
                    audit([archive], Path('llvm-nm'))


if __name__ == '__main__':
    unittest.main()
