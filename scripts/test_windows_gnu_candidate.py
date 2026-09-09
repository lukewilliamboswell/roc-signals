"""Fail-closed tool identity and target adapter checks for the private probe."""
import tempfile
from pathlib import Path
import unittest
from windows_gnu_build import compiler_args, identity, verify


class CandidateTests(unittest.TestCase):
    def test_tool_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fxc.exe'
            path.write_bytes(b'candidate')
            verify(path, identity(path)['sha256'])
            for value in ('', '0' * 64):
                with self.assertRaises(ValueError):
                    verify(path, value)
            pin = identity(path)['sha256']
            path.write_bytes(b'substituted')
            with self.assertRaises(ValueError):
                verify(path, pin)

    def test_compiler_preserves_safety_and_inputs(self):
        args = ['--target=x86_64-pc-windows-gnu', '-fsanitize=undefined', '-fstack-protector', 'a.c']
        self.assertEqual(compiler_args('cc', args),
                         ['cc', '-target', 'x86_64-windows-gnu', '-mcpu=baseline', *args[1:]])
        self.assertEqual(compiler_args('ar', ['crs', 'out.a', 'input.o']),
                         ['ar', 'crs', 'out.a', 'input.o'])
