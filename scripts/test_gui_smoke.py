"""A successful process exit alone does not prove a GUI rendered."""

from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gui_smoke


class GuiSmokeTests(unittest.TestCase):
    def test_requires_success_and_explicit_render_result(self):
        for code, stderr, expected in (
            (0, "", ValueError),
            (1, gui_smoke.MARKER + "1 retained views\n", subprocess.CalledProcessError),
        ):
            with self.subTest(code=code), patch.object(gui_smoke.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], code, stdout="", stderr=stderr)):
                with self.assertRaises(expected):
                    gui_smoke.check(Path("counter"))

    def test_successful_render_has_bounded_process_lifetime(self):
        with patch.object(gui_smoke.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout="", stderr=gui_smoke.MARKER + "1 retained views\n")) as run:
            gui_smoke.check(Path("counter"), ("--smoke-click", "Increment"))
        self.assertEqual(run.call_args.kwargs["timeout"], 30)
        self.assertIn("--smoke", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
