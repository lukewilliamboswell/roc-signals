"""Driver paths and test manifests remain stable across routine formatting."""

import ast
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
    def test_default_suite_is_all(self) -> None:
        with patch.object(sys, "argv", ["test.py"]):
            self.assertEqual(test_driver.parse_args().suites, ["all"])

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


class OutputDirectoryTests(unittest.TestCase):
    def test_default_output_is_unique_per_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(test_driver, "TEST_OUT_PARENT", Path(directory)):
            first = test_driver.create_test_output(None)
            second = test_driver.create_test_output(None)

        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, second.parent)

    def test_explicit_output_must_be_unowned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "named-run"
            self.assertEqual(test_driver.create_test_output(output), output)
            with self.assertRaisesRegex(SystemExit, "already exists"):
                test_driver.create_test_output(output)

    def test_native_wrapper_places_binaries_in_the_current_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(test_driver, "TEST_OUT", Path(directory)), \
                patch.object(test_driver, "rewrite_examples_for_platform"), \
                patch.object(test_driver, "run_native_specs") as run_native:
            test_driver.run_local_native_specs(
                "roc",
                (),
                jobs=None,
                spec_filters=(),
                shard=None,
                fail_fast=False,
                spec_timeout=30.0,
                ledger=object(),
            )

        self.assertEqual(run_native.call_args.kwargs["bin_dir"], Path(directory) / "bin")


class EffectContractTests(unittest.TestCase):
    def test_fault_campaign_enables_jspi(self) -> None:
        tree = ast.parse(Path(test_driver.__file__).read_text(encoding="utf-8"))
        commands = [node for node in ast.walk(tree) if isinstance(node, ast.List)
                    and any(isinstance(value, ast.Constant)
                            and value.value == "scripts/browser/coordinated_writes_faults.mjs"
                            for value in node.elts)]
        self.assertEqual(len(commands), 1)
        self.assertEqual([value.value for value in commands[0].elts[:3]],
                         ["node", "--no-maglev", "--experimental-wasm-jspi"])

    def test_release_mount_commands_enable_jspi(self) -> None:
        for name in ("release.py", "site_release.py"):
            tree = ast.parse(Path(__file__).with_name(name).read_text(encoding="utf-8"))
            commands = [node for node in ast.walk(tree) if isinstance(node, ast.List)
                        and any(isinstance(value, ast.Constant)
                                and value.value == "scripts/browser/mount_wasm_example.mjs"
                                for value in ast.walk(node))]
            with self.subTest(controller=name):
                self.assertEqual(len(commands), 1)
                self.assertEqual([value.value for value in commands[0].elts[:3]],
                                 ["node", "--no-maglev", "--experimental-wasm-jspi"])

    def test_linked_contracts_build_each_fixture_before_running_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            steps = []
            with patch.object(test_driver, "TEST_OUT", output), \
                    patch.object(test_driver, "run", side_effect=lambda command: steps.append(("run", command))) as run, \
                    patch.object(test_driver, "instrument_wasm", side_effect=lambda path: steps.append(("instrument", path))):
                test_driver.run_wasm_effect_contracts("selected-roc")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(len(commands), 4)
            for index, fixture in enumerate(("action", "http")):
                build, execute = commands[index * 2:index * 2 + 2]
                wasm = output / "wasm-effects" / f"{fixture}.wasm"
                self.assertEqual(steps[index * 3:index * 3 + 3], [
                    ("run", build), ("instrument", wasm), ("run", execute),
                ])
                self.assertEqual(build[0], "selected-roc")
                self.assertIn("--no-cache", build)
                self.assertIn(f"--output={wasm}", build)
                self.assertEqual(build[-1], test_driver.ROOT / "test" / "wasm" / fixture / "main.roc")
                self.assertEqual(execute[:3], ["node", "--no-maglev", "--experimental-wasm-jspi"])
                self.assertEqual(execute[-1], wasm)


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
