"""Guard CI selection against skipping affected or unclassified source."""

import unittest
from ci_changes import AREAS, classify, verify_results


class ChangeSelectionTests(unittest.TestCase):
    def test_gate_accepts_only_intentional_skips_and_successes(self):
        results = {"changes": {"result": "success", "outputs": {
            area: "true" if area == "gui" else "false" for area in AREAS
        }}}
        for job in ("source", "gui", "gui-windows", "gui-macos", "published", "archive", "site"):
            results[job] = {"result": "success" if job.startswith("gui") else "skipped"}
        verify_results(results)
        for bad in ("failure", "cancelled", "skipped"):
            results["gui"]["result"] = bad
            with self.assertRaises(ValueError):
                verify_results(results)
        results["gui"]["result"] = "success"
        results["changes"]["result"] = "failure"
        with self.assertRaises(ValueError):
            verify_results(results)

    def selected(self, paths):
        return {name for name, enabled in classify(paths).items() if enabled}

    def test_unknown_and_shared_changes_run_every_area(self):
        for path in ("new-component/input", "build.zig", "Cargo.lock",
                     ".github/workflows/ci.yml", "new-component/fixture.md", "src/signals/engine.zig",
                     "platform-shared/Signal.roc", "dependencies.lock.json"):
            self.assertEqual(self.selected([path]), AREAS, path)

    def test_gui_changes_do_not_run_browser_or_web_release_jobs(self):
        self.assertEqual(self.selected(["crates/gpui-host/src/lib.rs", "test/gui/task/main.roc"]), {"gui"})

    def test_documentation_changes_select_site(self):
        self.assertEqual(self.selected(["www/content/docs/contributing.md"]), {"site"})

    def test_runtime_javascript_is_not_treated_as_documentation(self):
        self.assertIn("source", self.selected(["www/static/signals.mjs"]))

    def test_multiple_areas_are_unioned(self):
        self.assertEqual(self.selected(["docs/guide.md", "examples-gui/counter/main.roc"]), {"site", "gui"})

    def test_removed_gui_and_added_unknown_paths_trigger_full_validation(self):
        self.assertEqual(self.selected(["crates/gpui-host/src/lib.rs", "new-host/lib.rs"]), AREAS)


if __name__ == "__main__":
    unittest.main()
