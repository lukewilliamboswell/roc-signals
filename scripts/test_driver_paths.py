"""Driver paths and test manifests remain stable across routine formatting."""

from contextlib import chdir
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test as test_driver  # noqa: E402


class CompilerPathTests(unittest.TestCase):
    def test_relative_executable_survives_a_child_working_directory(self) -> None:
        relative = os.path.relpath(sys.executable)
        executable = test_driver.command_path(relative)
        self.assertTrue(Path(executable).is_absolute())
        with tempfile.TemporaryDirectory() as directory, chdir(directory):
            result = subprocess.run(
                [executable, "--version"], capture_output=True, check=True, text=True
            )
        self.assertIn("Python", result.stdout)

    def test_relative_path_lookup_is_also_resolved(self) -> None:
        with patch.object(test_driver.shutil, "which", return_value="tools/roc"):
            self.assertEqual(
                test_driver.command_path("roc"), str(Path("tools/roc").resolve())
            )

    def test_missing_explicit_path_is_rejected(self) -> None:
        with patch.object(Path, "exists", return_value=False):
            with self.assertRaisesRegex(SystemExit, "missing Roc compiler"):
                test_driver.command_path("missing/roc")


class FaultManifestTests(unittest.TestCase):
    def test_export_insertion_accepts_compact_and_multiline_manifests(self) -> None:
        for source in (
            'exports: ["roc_alloc", "roc_ui_command_buffer_len", "roc_ui_mount"]',
            'exports: [\n\t"roc_alloc",\n\t"roc_ui_command_buffer_len",\n\t"roc_ui_mount",\n]',
        ):
            with self.subTest(source=source):
                actual = test_driver.add_wasm_fault_exports(source)
                for name in ("roc_ui_debug_fail_allocation", "roc_ui_debug_allocation_attempts", "roc_ui_is_poisoned"):
                    self.assertEqual(actual.count(f'"{name}"'), 1)
                    self.assertLess(actual.index(name), actual.index("roc_ui_command_buffer_len"))
                self.assertEqual(actual.count('"roc_ui_command_buffer_len"'), 1)
                self.assertIn('"roc_ui_mount"', actual)

    def test_missing_or_ambiguous_anchor_is_rejected(self) -> None:
        for source in ('exports: []', 'exports: ["roc_ui_command_buffer_len", "roc_ui_command_buffer_len"]'):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "one Wasm export anchor"):
                test_driver.add_wasm_fault_exports(source)


if __name__ == "__main__":
    unittest.main()
