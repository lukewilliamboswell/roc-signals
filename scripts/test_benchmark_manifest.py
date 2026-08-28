#!/usr/bin/env python3
"""Coverage contract tests for the js-framework benchmark fixture."""

from __future__ import annotations

from pathlib import Path
import sys
import tomllib
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test as test_driver  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "examples/_fixtures/js-framework-benchmark/benchmarks.toml"


class BenchmarkManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        with MANIFEST.open("rb") as f:
            self.manifest = tomllib.load(f)

    def test_node_wasm_work_is_delegated_to_the_owned_harness_issue(self) -> None:
        self.assertEqual(
            "https://github.com/lukewilliamboswell/roc-signals/issues/19",
            self.manifest["browser_harness_issue"],
        )

    def test_all_official_operations_and_warmups_are_pinned(self) -> None:
        expected = {
            "create_1k": 0,
            "replace_1k": 5,
            "update_10k": 5,
            "select_1k": 5,
            "swap_1k": 5,
            "remove_1k": 5,
            "create_10k": 0,
            "append_1k_to_10k": 0,
            "clear_10k": 0,
        }
        operations = {case["id"]: case for case in self.manifest["operations"]}
        self.assertEqual(set(expected), set(operations))
        self.assertEqual(expected, {key: value["warmup_iterations"] for key, value in operations.items()})
        for operation in operations.values():
            self.assertTrue((MANIFEST.parent / operation["spec"]).is_file())
            self.assertGreater(operation["native_iterations"], 0)
            self.assertGreater(operation["native_samples"], 0)

    def test_all_official_memory_scenarios_are_pinned(self) -> None:
        expected = {
            "ready_memory": [],
            "run_memory": ["run"],
            "update_memory": ["run", "update", "update", "update", "update", "update"],
            "replace_memory": ["run", "run", "run", "run", "run"],
            "repeated_clear_memory": ["run", "clear"] * 5,
        }
        scenarios = {case["id"]: case["actions"] for case in self.manifest["memory_scenarios"]}
        self.assertEqual(expected, scenarios)
        for scenario in self.manifest["memory_scenarios"]:
            self.assertEqual("browser_process_memory", scenario["provider"])
            self.assertEqual("deferred_issue_19", scenario["availability"])
        fixture_source = (MANIFEST.parent / "main.roc").read_text(encoding="utf-8")
        for action in {action for actions in expected.values() for action in actions}:
            self.assertIn(f'Html.attr("id", "{action}")', fixture_source)

    def test_all_official_browser_audit_metrics_are_pinned(self) -> None:
        expected = {
            "startup_time": "browser_navigation",
            "consistently_interactive": "lighthouse",
            "script_bootup_time": "lighthouse",
            "main_thread_work_cost": "lighthouse",
            "total_byte_weight": "lighthouse",
        }
        metrics = {case["id"]: case["provider"] for case in self.manifest["browser_metrics"]}
        self.assertEqual(expected, metrics)
        for metric in self.manifest["browser_metrics"]:
            self.assertEqual("deferred_issue_19", metric["availability"])

    def test_test_driver_consumes_the_manifest(self) -> None:
        example = next(item for item in test_driver.load_examples() if item.slug == "js-framework-benchmark")
        cases = test_driver.load_benchmark_cases(example, ROOT)
        self.assertIsNotNone(cases)
        self.assertEqual(9, len(cases or ()))


if __name__ == "__main__":
    unittest.main()
