"""Unit tests for the GUI regression scenario driver."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gui_regression
from build_gui import executable_name


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

    def test_front_matter_queues_real_files_for_the_choosers_in_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures = root / "activity" / "regression" / "fixtures"
            fixtures.mkdir(parents=True)
            (fixtures / "events.log").write_text("one\n", encoding="utf-8")
            (fixtures / "project").mkdir()
            path = write(root, "activity", "follow",
                         "# choose: regression/fixtures/events.log\n"
                         "# choose: regression/fixtures/project\n"
                         "click \"Open log…\"\nclose\n")
            scenario = gui_regression.Scenario(root / "activity", path)
            self.assertEqual(scenario.choices, [fixtures / "events.log", fixtures / "project"])
            arguments = gui_regression.arguments_for(scenario, root / "report.json")
            self.assertEqual(arguments.count("--host-choose"), 2)
            self.assertLess(arguments.index(str((fixtures / "events.log").resolve())),
                            arguments.index(str((fixtures / "project").resolve())))

    def test_a_choice_that_names_nothing_on_disk_is_refused_up_front(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "activity", "follow",
                         "# choose: regression/fixtures/missing.log\nclose\n")
            with self.assertRaises(SystemExit):
                gui_regression.Scenario(root / "activity", path)

    def test_an_abnormal_exit_fails_the_scenario_even_with_a_passing_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "activity", "follow", "close\n")
            scenario = gui_regression.Scenario(root / "activity", path)
            artifacts = root / "artifacts"

            def fake_run(command, **_):
                report = Path(command[command.index("--host-script-report") + 1])
                report.parent.mkdir(parents=True, exist_ok=True)
                report.write_text('{"passed": true}', encoding="utf-8")
                return subprocess.CompletedProcess(command, -11, "", "PASS: follow\n")

            with patch.object(gui_regression.subprocess, "run", fake_run):
                passed, detail, _ = gui_regression.run_scenario(
                    root / "app", scenario, artifacts, capture=False)
            self.assertFalse(passed)
            self.assertIn("signal 11", detail)
            self.assertIn("PASS: follow", detail)

    def test_a_diagnostic_scoped_to_other_systems_is_an_ordinary_check_here(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "counter", "minimum", "# size: 360x240\n"
                         "# diagnostic: GUI-35. The Linux frame takes 48 pixels.\n"
                         "# diagnostic-on: linux\nexpect-onscreen #Increment\n")
            on_linux = gui_regression.Scenario(root / "counter", path, system="Linux")
            self.assertEqual(on_linux.diagnostic_for(None),
                             "GUI-35. The Linux frame takes 48 pixels.")
            on_mac = gui_regression.Scenario(root / "counter", path, system="Darwin")
            self.assertIsNone(on_mac.diagnostic_for("client"))
            on_windows = gui_regression.Scenario(root / "counter", path, system="Windows")
            self.assertIsNone(on_windows.diagnostic_for("server"))

    def test_a_diagnostic_scoped_to_the_window_frame_is_judged_from_the_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "counter", "minimum", "# size: 360x240\n"
                         "# diagnostic: GUI-35. The host frame takes 48 pixels.\n"
                         "# diagnostic-on: client-frame\nexpect-onscreen #Increment\n")
            scenario = gui_regression.Scenario(root / "counter", path, system="Linux")
            self.assertEqual(scenario.diagnostic_for("client"),
                             "GUI-35. The host frame takes 48 pixels.")
            self.assertIsNone(scenario.diagnostic_for("server"))
            self.assertIsNone(scenario.diagnostic_for(None))
            unscoped = write(root, "counter", "plain", "# diagnostic: GUI-03.\nexpect-text 1\n")
            self.assertEqual(gui_regression.Scenario(root / "counter", unscoped).diagnostic_for(None),
                             "GUI-03.")

    def test_a_diagnostic_scope_must_name_known_systems_and_a_diagnostic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write(root, "counter", "minimum",
                         "# diagnostic: GUI-35.\n# diagnostic-on: beos\nexpect-text 0\n")
            with self.assertRaises(SystemExit):
                gui_regression.Scenario(root / "counter", path, system="Linux")
            path = write(root, "counter", "unscoped",
                         "# diagnostic-on: linux\nexpect-text 0\n")
            with self.assertRaises(SystemExit):
                gui_regression.Scenario(root / "counter", path, system="Linux")

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
        # Name the stand-in the way the driver will look for it: on Windows that
        # is counter.exe, and a test that hardcodes the Unix spelling fails there
        # for a reason that has nothing to do with what it is checking.
        (binaries / executable_name("counter")).write_text("", encoding="utf-8")
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
