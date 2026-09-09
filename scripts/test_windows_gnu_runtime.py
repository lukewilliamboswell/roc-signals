"""Guard complete runtime source closure, weak aliases and signed publication."""

import io
import json
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_windows_gnu_runtime import corresponding_source, RECIPE
from release_windows_gnu_runtime import prepare
from windows_runtime_validation import ucrt_inventory


class RuntimeValidationTests(unittest.TestCase):
    def test_implementation_code_cannot_be_admitted_as_a_ucrt_alias(self):
        header = struct.pack('<HHIIIHH', 0x8664, 1, 0, 61, 0, 0, 0)
        section = struct.pack('<8sIIIIIIHHI', b'.text', 0, 0, 1, 60, 0, 0, 0, 0, 0x60000020)
        body = header + section + b'\xc3' + struct.pack('<I', 4)
        with patch('windows_runtime_validation.members', return_value=[('code.obj', body)]):
            with self.assertRaisesRegex(ValueError, 'implementation'):
                ucrt_inventory(b'not read by the fixture')

    def test_weak_alias_payload_or_policy_cannot_hide_implementation(self):
        # The pure weak-alias form has zero section bytes and SEARCH_ALIAS=3.
        name_table = b'\0\0\0\0target\0alias\0'
        records = [struct.pack('<8sIhHBB', name, 0, -1, 0, 3, 0) for name in (b'@comp.id', b'@feat.00')]
        records += [struct.pack('<8sIhHBB', struct.pack('<II', 0, 4), 0, 0, 0, 2, 0),
                    struct.pack('<8sIhHBB', struct.pack('<II', 0, 11), 0, 0, 0, 105, 1),
                    struct.pack('<II', 2, 1) + bytes(10)]
        strings = struct.pack('<I', len(name_table)) + name_table[4:]
        body = struct.pack('<HHIIIHH', 0x8664, 1, 0, 60, 5, 0, 0)
        body += struct.pack('<8sIIIIIIHHI', b'.drectve', 0, 0, 0, 0, 0, 0, 0, 0, 0xA00)
        body += b''.join(records) + strings
        with patch('windows_runtime_validation.members', return_value=[('alias.obj', body)]):
            with self.assertRaisesRegex(ValueError, 'weak external policy'):
                ucrt_inventory(b'fixture')
        modified = bytearray(body)
        struct.pack_into('<I', modified, 36, 1)
        with patch('windows_runtime_validation.members', return_value=[('alias.obj', bytes(modified))]):
            with self.assertRaisesRegex(ValueError, 'section payload'):
                ucrt_inventory(b'fixture')

    def test_zig_libc_entry_point_has_its_implementation_directory(self):
        recipe = json.loads(RECIPE.read_text())
        # lib/c.zig imports these modules; shipping only the root entry point
        # cannot reproduce the packaged zigc implementation.
        self.assertIn('lib/c.zig', recipe['source_files'])
        self.assertIn('lib/c', recipe['source_directories'])

    def test_source_payload_preserves_notices_but_excludes_unselected_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, text in {'LICENSE': 'original terms\n', 'lib/libc/mingw/a.c': '/* original notice */\n',
                               'lib/include/stddef.h': 'clang notice\n', 'lib/libc/include/any-windows-any/windows.h': 'mingw notice\n',
                               'lib/libc/include/generic-glibc/foreign.h': 'unrelated\n'}.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            recipe = {'source_files': ['LICENSE'], 'source_directories': ['lib/libc/mingw'],
                      'headers': ['lib/include', 'lib/libc/include/any-windows-any']}
            first = corresponding_source(root, recipe)
            self.assertEqual(first, corresponding_source(root, recipe))
            with tarfile.open(fileobj=io.BytesIO(first)) as archive:
                self.assertNotIn('lib/libc/include/generic-glibc/foreign.h', archive.getnames())
                self.assertEqual(archive.extractfile('lib/libc/mingw/a.c').read(), b'/* original notice */\n')
                self.assertTrue(all(member.mtime == 0 and member.uid == 0 for member in archive))
            (root / 'lib/libc/mingw/alias.c').symlink_to(root / 'LICENSE')
            with self.assertRaisesRegex(ValueError, 'source link'):
                corresponding_source(root, recipe)


class PublicationTests(unittest.TestCase):
    def test_signature_failure_prevents_extraction_and_lock_creation(self):
        sha = '1' * 40
        environment = {'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                       'GITHUB_REPOSITORY': 'lukewilliamboswell/roc-signals', 'GITHUB_SHA': sha}
        with tempfile.TemporaryDirectory() as temporary, patch('release_windows_gnu_runtime.subprocess.check_output', return_value=sha):
            root = Path(temporary)
            (root / 'windows-gnu-runtime-x64mingw.tar').write_bytes(b'unattested')
            with patch('release_windows_gnu_runtime.verify_archive', side_effect=ValueError('signature rejected')) as verifier, patch('release_windows_gnu_runtime.unpack_verified') as unpack:
                with self.assertRaisesRegex(ValueError, 'signature rejected'):
                    prepare(root, 'deps-windows-gnu-runtime-1', environment)
                verifier.assert_called_once()
                unpack.assert_not_called()
            self.assertFalse((root / 'dependencies.lock.json').exists())

    def test_ordinary_pull_request_cannot_publish(self):
        with self.assertRaises(ValueError):
            prepare(Path('/missing'), 'deps-windows-gnu-runtime-1', {'GITHUB_EVENT_NAME': 'pull_request'})


if __name__ == '__main__':
    unittest.main()
