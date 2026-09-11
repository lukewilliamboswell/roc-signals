"""GUI discovery must not silently omit an app or its semantic specs."""

from pathlib import Path
import json
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import build_gui
import gui_suite


class GuiDiscoveryTests(unittest.TestCase):
    def test_development_and_release_builds_select_both_compiler_profiles(self):
        for debug in (True, False):
            with self.subTest(debug=debug), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                target = root / 'target'
                profile = target / ('debug' if debug else 'release')
                profile.mkdir(parents=True)
                (profile / 'libsignals_gpui_host.a').write_bytes(b'rust')
                engine = root / 'zig-out/gui/libengine.a'
                engine.parent.mkdir(parents=True)
                engine.write_bytes(b'zig')
                (root / 'platform-gui/targets/macos-sysroot').mkdir(parents=True)
                with patch.object(build_gui, 'ROOT', root), \
                        patch.object(build_gui, 'host_target', return_value='arm64mac'), \
                        patch.object(build_gui.platform, 'system', return_value='Darwin'), \
                        patch.object(build_gui.subprocess, 'check_output', return_value=json.dumps({'target_directory': str(target)})), \
                        patch.object(build_gui.subprocess, 'run') as run:
                    build_gui.build(debug=debug)
                commands = [call.args[0] for call in run.call_args_list]
                zig = next(command for command in commands if command[0] == 'zig')
                cargo = next(command for command in commands if command[0] == 'cargo')
                self.assertIn('-Doptimize=' + ('Debug' if debug else 'ReleaseFast'), zig)
                self.assertEqual('--release' in cargo, not debug)
                self.assertEqual((root / 'platform-gui/targets/arm64mac/libengine.a').read_bytes(), b'zig')

    def test_development_build_cannot_claim_release_evidence(self):
        with patch.object(build_gui, 'host_target', return_value='arm64mac'), \
                patch.object(build_gui.subprocess, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'requires an optimized build'):
                build_gui.build(debug=True, cargo_evidence=Path('evidence'))
        run.assert_not_called()

    def test_macos_target_links_the_staged_system_interface(self):
        header = (gui_suite.ROOT / "platform-gui/main.roc").read_text()
        self.assertIn('"../macos-sysroot/usr/lib/libSystem.tbd"', header)

    def test_supported_hosts_match_platform_targets(self):
        for system, machine, expected in [('Linux', 'x86_64', 'x64glibc'),
                                          ('Darwin', 'arm64', 'arm64mac'),
                                          ('Windows', 'AMD64', 'x64mingw'),
                                          ('Windows', 'ARM64', None),
                                          ('Darwin', 'x86_64', None),
                                          ('Linux', 'aarch64', None)]:
            with self.subTest(system=system, machine=machine), \
                    patch('build_gui.platform.system', return_value=system), \
                    patch('build_gui.platform.machine', return_value=machine):
                self.assertEqual(build_gui.host_target(), expected)
                self.assertEqual(gui_suite.supported_host(), expected is not None)

    def test_repository_apps_all_have_registered_specs(self):
        self.assertTrue(gui_suite.examples())

    def test_unregistered_app_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "examples-gui"
            (directory / "extra").mkdir(parents=True)
            (directory / "extra/main.roc").write_text("app")
            (directory / "examples.toml").write_text('schema_version = 1\n[[examples]]\nslug = "counter"\n')
            with self.assertRaisesRegex(ValueError, "differs from app directories"):
                gui_suite.examples(root)

    def test_registered_app_without_specs_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "examples-gui"
            (directory / "counter/specs").mkdir(parents=True)
            (directory / "counter/main.roc").write_text("app")
            (directory / "examples.toml").write_text('schema_version = 1\n[[examples]]\nslug = "counter"\n')
            with self.assertRaisesRegex(ValueError, "no .*scm files"):
                gui_suite.examples(root)

    def test_internal_fixture_without_specs_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "test/gui/presentation"
            (directory / "specs").mkdir(parents=True)
            (directory / "main.roc").write_text("app")
            with self.assertRaisesRegex(ValueError, "no .*scm files"):
                gui_suite.fixtures(root)

    def test_no_internal_fixtures_is_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(gui_suite.fixtures(Path(temporary)), ())

    def test_prebuilt_host_replaces_build_and_cargo_tests(self):
        args = SimpleNamespace(
            gui_host_lock=Path("host.lock"), gui_build_jobs=2, spec_filter=[], shard=None,
            jobs=1, fail_fast=False, spec_timeout=30,
        )
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(gui_suite, "examples", return_value=()), \
                patch.object(gui_suite, "fixtures", return_value=()), \
                patch.object(gui_suite.toolchain, "verify_compiler"), \
                patch.object(gui_suite.toolchain, "read_pin"), \
                patch.object(gui_suite, "install_prebuilt_host") as install, \
                patch("gui_host_artifacts.lock_matches_sources", return_value=True), \
                patch.object(gui_suite.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "no GUI specs matched"):
                gui_suite.run("roc", args, Path(temporary) / "output")
        install.assert_called_once_with(Path("host.lock"), build_gui.host_target())
        self.assertFalse(any(command.args[0][0] == "cargo" for command in run.call_args_list))

    def test_a_lock_from_before_a_host_change_builds_and_tests_the_host(self):
        """The case that would otherwise make a host change unmergeable."""
        args = SimpleNamespace(
            gui_host_lock=Path("host.lock"), gui_build_jobs=2, spec_filter=(), shard=None,
            jobs=1, fail_fast=False, spec_timeout=30,
        )
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(gui_suite, "examples", return_value=()), \
                patch.object(gui_suite, "fixtures", return_value=()), \
                patch.object(gui_suite.toolchain, "verify_compiler"), \
                patch.object(gui_suite.toolchain, "read_pin"), \
                patch.object(gui_suite, "install_prebuilt_host") as install, \
                patch("gui_host_artifacts.lock_matches_sources", return_value=False), \
                patch.object(gui_suite.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "no GUI specs matched"):
                gui_suite.run("roc", args, Path(temporary) / "output")
        install.assert_not_called()
        commands = [command.args[0] for command in run.call_args_list]
        self.assertTrue(any(str(part).endswith("build_gui.py") for command in commands
                            for part in command))
        build = next(command for command in commands if any(str(part).endswith("build_gui.py") for part in command))
        self.assertIn('--debug', build)
        self.assertTrue(any(command[0] == "cargo" for command in commands))


if __name__ == "__main__":
    unittest.main()
