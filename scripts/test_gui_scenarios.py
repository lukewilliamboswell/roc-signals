"""Unit tests for the window scenario driver."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gui_scenarios
from build_gui import executable_name


def write(directory: Path, app: str, name: str, text: str) -> Path:
    specs = directory / app / "specs"
    specs.mkdir(parents=True, exist_ok=True)
    path = specs / f"{name}.scm"
    path.write_text(text, encoding="utf-8")
    return path


class DiscoveryTests(unittest.TestCase):
    def test_only_scenario_forms_are_collected_from_the_shared_specs_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "counter", "counting", '(test "counting" (steps (expect-text (test-id "count") "0")))\n')
            write(root, "counter", "minimum", '; a window check\n(scenario "minimum" :window "360x240"\n  (steps (expect-onscreen (test-id "count"))))\n')
            found = gui_scenarios.scenarios([root / "counter"])
            self.assertEqual([str(scenario) for scenario in found], ["counter/minimum"])
            arguments = gui_scenarios.arguments_for(found[0], root / "report.json")
            self.assertEqual(arguments[0], "--host-scenario")
            self.assertNotIn("--host-window-size", arguments)

    def test_an_example_without_scenarios_fails_instead_of_shortening_the_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "counter", "counting", '(test "counting" (steps (expect-text (test-id "count") "0")))\n')
            with self.assertRaises(SystemExit):
                gui_scenarios.scenarios([root / "counter"])


class DiagnosticTests(unittest.TestCase):
    def test_an_unscoped_diagnostic_applies_everywhere(self):
        report = {"diagnostic": "GUI-03.", "frame": "server"}
        self.assertEqual(gui_scenarios.diagnostic_for(report, system="Darwin"), "GUI-03.")
        self.assertIsNone(gui_scenarios.diagnostic_for({"frame": "client"}))

    def test_a_scope_is_judged_from_the_system_and_the_reported_frame(self):
        report = {"diagnostic": "GUI-35.", "diagnostic_on": ["client-frame", "windows"], "frame": "client"}
        self.assertEqual(gui_scenarios.diagnostic_for(report, system="Linux"), "GUI-35.")
        self.assertEqual(gui_scenarios.diagnostic_for(dict(report, frame="server"), system="Windows"), "GUI-35.")
        self.assertIsNone(gui_scenarios.diagnostic_for(dict(report, frame="server"), system="Darwin"))


class RunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        write(self.root, "counter", "counting", '(scenario "counting" (steps (expect-visible (text "0"))))\n')
        write(self.root, "counter", "known", '(scenario "known" :diagnostic "GUI-03." (steps (expect-visible (text "1"))))\n')
        binaries = self.root / "built"
        binaries.mkdir()
        # Name the stand-in the way the driver will look for it: on Windows that
        # is counter.exe, and a test that hardcodes the Unix spelling fails there
        # for a reason that has nothing to do with what it is checking.
        (binaries / executable_name("counter")).write_text("", encoding="utf-8")
        self.binaries = binaries

    def outcome(self, results):
        def run_scenario(executable, scenario, artifacts, capture, environment=None):
            passed, failure = results[scenario.name]
            report = {"passed": passed, "failure": failure, "frame": "server"}
            if scenario.name == "known":
                report["diagnostic"] = "GUI-03."
            return passed, failure, report

        return patch.object(gui_scenarios, "run_scenario", run_scenario)

    def test_a_reproduced_diagnostic_does_not_fail_the_run(self):
        with self.outcome({"counting": (True, ""), "known": (False, "still clipped")}):
            gui_scenarios.run(self.binaries, self.root / "artifacts",
                              apps=[self.root / "counter"], capture=False)

    def test_a_failing_check_fails_the_run(self):
        with self.outcome({"counting": (False, "text missing"), "known": (False, "x")}):
            with self.assertRaises(SystemExit) as raised:
                gui_scenarios.run(self.binaries, self.root / "artifacts",
                                  apps=[self.root / "counter"], capture=False)
            self.assertIn("text missing", str(raised.exception))

    def test_a_diagnostic_that_starts_passing_fails_the_run(self):
        with self.outcome({"counting": (True, ""), "known": (True, "")}):
            with self.assertRaises(SystemExit) as raised:
                gui_scenarios.run(self.binaries, self.root / "artifacts",
                                  apps=[self.root / "counter"], capture=False)
            self.assertIn("promote it", str(raised.exception))

    def test_a_missing_executable_is_reported_before_anything_is_run(self):
        with self.assertRaises(SystemExit) as raised:
            gui_scenarios.run(self.root / "absent", self.root / "artifacts",
                              apps=[self.root / "counter"], capture=False)
        self.assertIn("build the GUI examples first", str(raised.exception))

    def test_an_abnormal_exit_fails_the_scenario_even_with_a_passing_report(self):
        scenario = gui_scenarios.scenarios([self.root / "counter"], ("counting",))[0]

        def fake_run(command, **_):
            report = Path(command[command.index("--host-scenario-report") + 1])
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text('{"passed": true}', encoding="utf-8")
            return subprocess.CompletedProcess(command, -11, "", "PASS: counting\n")

        with patch.object(gui_scenarios.subprocess, "run", fake_run):
            passed, detail, report = gui_scenarios.run_scenario(
                self.root / "app", scenario, self.root / "artifacts", capture=False)
        self.assertFalse(passed)
        self.assertIn("signal 11", detail)
        self.assertIn("PASS: counting", detail)
        self.assertEqual(report, {})

    def test_the_hosts_own_failed_step_verdict_is_read_from_the_report(self):
        scenario = gui_scenarios.scenarios([self.root / "counter"], ("counting",))[0]

        def fake_run(command, **_):
            report = Path(command[command.index("--host-scenario-report") + 1])
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text('{"passed": false, "failure": "line 3: gone", "frame": "client"}',
                              encoding="utf-8")
            return subprocess.CompletedProcess(command, 1, "", "FAIL: counting: line 3: gone\n")

        with patch.object(gui_scenarios.subprocess, "run", fake_run):
            passed, detail, report = gui_scenarios.run_scenario(
                self.root / "app", scenario, self.root / "artifacts", capture=False)
        self.assertFalse(passed)
        self.assertEqual(detail, "line 3: gone")
        self.assertEqual(report["frame"], "client")


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

        with patch.object(gui_smoke, "wayland", fake_wayland), \
                patch.object(gui_scenarios, "run", fake_run), \
                patch.object(sys, "argv", [
                    "gui_scenarios.py", "--wayland", "--no-capture",
                    "--directory", "/gui-output",
                ]):
            gui_scenarios.main()
        self.assertEqual(captured["environment"], {"WAYLAND_DISPLAY": "signals-smoke"})
        self.assertFalse(captured["capture"])


if __name__ == "__main__":
    unittest.main()
