"""Guard CI selection against skipping affected or unclassified source."""

import unittest
from ci_changes import AREAS, classify, verify_results


class ChangeSelectionTests(unittest.TestCase):
    def test_gate_accepts_only_intentional_skips_and_successes(self):
        results = {"changes": {"result": "success", "outputs": {
            "source": "true", "site": "false",
        }}}
        results["source"] = {"result": "success"}
        results["site"] = {"result": "skipped"}
        verify_results(results)
        for bad in ("failure", "cancelled", "skipped"):
            results["source"]["result"] = bad
            with self.assertRaises(ValueError):
                verify_results(results)
        results["source"]["result"] = "success"
        results["site"]["result"] = "success"
        with self.assertRaises(ValueError):
            verify_results(results)
        results["site"]["result"] = "skipped"
        results["changes"]["result"] = "failure"
        with self.assertRaises(ValueError):
            verify_results(results)

    def selected(self, paths):
        return {name for name, enabled in classify(paths).items() if enabled}

    def test_unknown_and_shared_changes_run_every_area(self):
        for path in ("new-component/input", "build.zig", ".github/workflows/ci.yml",
                     "new-component/fixture.md", "dependencies.lock.json"):
            self.assertEqual(self.selected([path]), AREAS, path)

    def test_engine_platform_and_spec_sources_run_every_area(self):
        for path in ("src/signals/engine.zig", "platform-shared/Signal.roc", "src/native_host.zig",
                     "src/spec/spec_parser.zig", "src/sim_dom.zig", "protocol/native-protocol.json",
                     "platform-web/main.roc", "examples-web/counter/main.roc", "src/wasm_host.zig"):
            self.assertEqual(self.selected([path]), AREAS, path)

    def test_documentation_changes_select_site(self):
        self.assertEqual(self.selected(["www/content/docs/contributing.md"]), {"site"})
        self.assertEqual(self.selected(["design.md", "releases/unreleased.md"]), {"site"})

    def test_runtime_javascript_is_not_treated_as_documentation(self):
        self.assertIn("source", self.selected(["www/static/signals.mjs"]))

    def test_multiple_areas_are_unioned(self):
        self.assertEqual(self.selected(["docs/guide.md", "examples-web/counter/main.roc"]), AREAS)


if __name__ == "__main__":
    unittest.main()
