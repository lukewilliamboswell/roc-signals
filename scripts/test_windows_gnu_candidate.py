"""Fail-closed tool identity and target adapter checks for the shared Windows host builder."""
import tempfile
from contextlib import nullcontext
from unittest.mock import patch
import build_gui
import prepare_dependencies
import windows_gnu_build
import windows_gnu_coff
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

    def test_repeated_build_and_failed_normalization_preserve_published_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / 'platform-gui/targets/x64mingw'
            destination.mkdir(parents=True)
            def execute(mode, output, **kwargs):
                payload = output / 'payload'
                payload.mkdir(parents=True)
                for name in ('libsignals_gpui_host.a', 'libengine.a', 'signals.res'):
                    (payload / name).write_bytes(b'raw-' + name.encode())
                return payload
            def normalize(source, output, inventory, zig):
                with output.open('xb') as stream:
                    stream.write(b'complete-host')
                return {'normalization': 'complete'}
            with patch.object(build_gui, 'ROOT', root), \
                    patch.object(prepare_dependencies, 'install_windows_gnu', return_value={}), \
                    patch.object(prepare_dependencies, 'verified_windows_gnu', side_effect=lambda: nullcontext(root)), \
                    patch.object(prepare_dependencies, 'windows_gnu_inventory', return_value={}), \
                    patch.object(windows_gnu_build, 'execute', side_effect=execute), \
                    patch.object(windows_gnu_coff, 'normalize', side_effect=normalize) as transform:
                build_gui.build_windows(False, 2, None)
                build_gui.build_windows(False, 2, None)
                before = {p.name: p.read_bytes() for p in destination.iterdir()}
                def fail(source, output, inventory, zig):
                    output.write_bytes(b'partial')
                    raise ValueError('indexing failed')
                transform.side_effect = fail
                with self.assertRaisesRegex(ValueError, 'indexing failed'):
                    build_gui.build_windows(False, 2, None)
                self.assertEqual(before, {p.name: p.read_bytes() for p in destination.iterdir()})

    def test_changed_shader_tools_are_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fxc, dll = root / 'fxc.exe', root / 'd3dcompiler_47.dll'
            fxc.write_bytes(b'fxc')
            dll.write_bytes(b'compiler')
            signatures = [{'Path': str(path), 'Status': 0, 'Thumbprint': windows_gnu_build.SIGNER}
                          for path in (fxc, dll)]
            with patch.object(windows_gnu_build.subprocess, 'check_output') as execute:
                with self.assertRaisesRegex(ValueError, 'unreviewed tool identity'):
                    windows_gnu_build.probe_fxc('build', fxc, dll, signatures, root)
                execute.assert_not_called()
                with patch.object(windows_gnu_build, 'FXC_SHA', identity(fxc)['sha256']), \
                        patch.object(windows_gnu_build, 'COMPILER_SHA', identity(dll)['sha256']):
                    signatures[1]['Status'] = 1
                    with self.assertRaisesRegex(ValueError, 'Authenticode'):
                        windows_gnu_build.probe_fxc('build', fxc, dll, signatures, root)
                    execute.assert_not_called()
                    signatures[1]['Status'] = 0
                    execute.return_value = '{"path": "actual-loaded-dll"}'
                    self.assertEqual(windows_gnu_build.probe_fxc('build', fxc, dll, signatures, root),
                                     {'path': 'actual-loaded-dll'})
                    execute.assert_called_once()
