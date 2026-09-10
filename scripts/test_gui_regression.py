"""Unit tests for the GUI regression scenario driver."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gui_regression


def write(directory: Path, app: str, name: str, text: str) -> Path:
    scripts = directory / app / "regression"
    scripts.mkdir(parents=True, exist_ok=True)
    path = scripts / f"{name}.script"
    path.write_text(text, encoding="utf-8")
    return path


class ScenarioTests(unittest.TestCase):
    def test_front_matter_supplies_the_size_and_the_diagnostic_reason(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "board", "detail", "# size: 800x600\n"
                         "# diagnostic: GUI-03. The detail panel is laid out\n"
                         "# below the window.\nexpect-onscreen #task-detail\n")
            scenario = gui_regression.Scenario(root / "board", path)
            self.assertEqual(scenario.size, "800x600")
            self.assertEqual(
                scenario.diagnostic,
                "GUI-03. The detail panel is laid out below the window.",
            )
            self.assertEqual(str(scenario), "board/detail")

    def test_a_scenario_without_front_matter_uses_the_review_size_and_is_a_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "counter", "counting", "expect-text 0\n")
            scenario = gui_regression.Scenario(root / "counter", path)
            self.assertEqual(scenario.size, gui_regression.DEFAULT_SIZE)
            self.assertIsNone(scenario.diagnostic)

    def test_an_unusable_size_is_refused_rather_than_silently_defaulted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "counter", "counting", "# size: small\nexpect-text 0\n")
            with self.assertRaises(SystemExit):
                gui_regression.Scenario(root / "counter", path)

    def test_an_example_without_scenarios_fails_instead_of_shortening_the_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "counter").mkdir()
            with self.assertRaises(SystemExit):
                gui_regression.scenarios([root / "counter"])

    def test_comments_inside_a_script_body_do_not_extend_the_diagnostic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "notes", "dialog",
                         "# diagnostic: GUI-04.\nclick New\n# a later note\n")
            scenario = gui_regression.Scenario(root / "notes", path)
            self.assertEqual(scenario.diagnostic, "GUI-04.")


class RunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        write(self.root, "counter", "counting", "expect-text 0\n")
        write(self.root, "counter", "known", "# diagnostic: GUI-03.\nexpect-text 1\n")
        binaries = self.root / "built"
        binaries.mkdir()
        (binaries / "counter").write_text("", encoding="utf-8")
        self.binaries = binaries

    def outcome(self, results):
        def run_scenario(executable, scenario, artifacts, capture, environment=None):
            return results[scenario.name]

        return patch.object(gui_regression, "run_scenario", run_scenario)

    def test_a_reproduced_diagnostic_does_not_fail_the_run(self):
        with self.outcome({"counting": (True, ""), "known": (False, "still clipped")}):
            gui_regression.run(self.binaries, self.root / "artifacts",
                               apps=[self.root / "counter"], capture=False)

    def test_a_failing_check_fails_the_run(self):
        with self.outcome({"counting": (False, "text missing"), "known": (False, "x")}):
            with self.assertRaises(SystemExit) as raised:
                gui_regression.run(self.binaries, self.root / "artifacts",
                                   apps=[self.root / "counter"], capture=False)
            self.assertIn("text missing", str(raised.exception))

    def test_a_diagnostic_that_starts_passing_fails_the_run(self):
        with self.outcome({"counting": (True, ""), "known": (True, "")}):
            with self.assertRaises(SystemExit) as raised:
                gui_regression.run(self.binaries, self.root / "artifacts",
                                   apps=[self.root / "counter"], capture=False)
            self.assertIn("promote it", str(raised.exception))

    def test_a_missing_executable_is_reported_before_anything_is_run(self):
        with self.assertRaises(SystemExit) as raised:
            gui_regression.run(self.root / "absent", self.root / "artifacts",
                               apps=[self.root / "counter"], capture=False)
        self.assertIn("build the GUI examples first", str(raised.exception))


class WaylandDispatch(unittest.TestCase):
    """The Linux path has to reuse one private compositor, not start its own."""

    def test_wayland_runs_the_scenarios_inside_the_shared_compositor(self):
        import gui_smoke

        captured = {}

        def fake_wayland(directory, action=None):
            captured["directory"] = directory
            action(directory, {"WAYLAND_DISPLAY": "signals-smoke"})

        def fake_run(directory, artifacts, patterns, capture, environment):
            captured["environment"] = environment
            captured["capture"] = capture

        argv = ["gui_regression.py", "--wayland", "--directory", "/tmp/apps", "--no-capture"]
        with patch.object(gui_smoke, "wayland", fake_wayland), \
                patch.object(gui_regression, "run", fake_run), \
                patch.object(sys, "argv", argv):
            gui_regression.main()
        self.assertEqual(captured["directory"], Path("/tmp/apps"))
        self.assertEqual(captured["environment"]["WAYLAND_DISPLAY"], "signals-smoke")
        self.assertFalse(captured["capture"])


if __name__ == "__main__":
    unittest.main()
