"""Atomic publication tests for mandatory Wasm stack instrumentation."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from instrument_wasm import instrument_wasm


class InstrumentationTests(unittest.TestCase):
    def test_existing_stack_export_is_rejected_without_rewriting(self):
        # Valid minimal Wasm exporting an empty __set_stack_limits function.
        # Exercise the actual Node preflight, not a mocked subprocess result.
        name = b"__set_stack_limits"
        export = bytes([1, len(name)]) + name + bytes([0, 0])
        module = (
            b"\x00asm\x01\x00\x00\x00"
            b"\x01\x04\x01\x60\x00\x00"
            b"\x03\x02\x01\x00"
            + bytes([7, len(export)]) + export
            + b"\x0a\x04\x01\x02\x00\x0b"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.wasm"
            path.write_bytes(module)
            subprocess.run(
                ["node", "--input-type=module", "-e",
                 "import {readFileSync} from 'node:fs'; new WebAssembly.Module(readFileSync(process.argv[1]));",
                 str(path)], capture_output=True, check=True,
            )
            with self.assertRaises(subprocess.CalledProcessError):
                instrument_wasm(path)
            self.assertEqual(path.read_bytes(), module)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def exercise(self, failing_step):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.wasm"
            path.write_bytes(b"original")
            calls = []

            def run(command, *, check):
                self.assertTrue(check)
                calls.append(command)
                self.assertEqual(path.read_bytes(), b"original")
                if len(calls) == failing_step:
                    raise subprocess.CalledProcessError(1, command)
                if command[0] == "wasm-opt":
                    self.assertIn("--stack-check", command)
                    self.assertIn("--strip-debug", command)
                    Path(command[-1]).write_bytes(b"instrumented")
                else:
                    self.assertEqual(command[0], "node")
                    expected = b"original" if len(calls) == 1 else b"instrumented"
                    self.assertEqual(Path(command[-1]).read_bytes(), expected)

            with patch("instrument_wasm.subprocess.run", side_effect=run):
                if failing_step:
                    with self.assertRaises(subprocess.CalledProcessError):
                        instrument_wasm(path)
                else:
                    instrument_wasm(path)
            self.assertEqual(path.read_bytes(), b"original" if failing_step else b"instrumented")
            self.assertEqual(list(Path(directory).iterdir()), [path])
            self.assertEqual(len(calls), failing_step or 3)

    def test_preflight_failure_preserves_input(self):
        self.exercise(1)

    def test_instrumentation_failure_preserves_input(self):
        self.exercise(2)

    def test_validation_failure_preserves_input(self):
        self.exercise(3)

    def test_publication_follows_validation(self):
        self.exercise(None)


if __name__ == "__main__":
    unittest.main()
