#!/usr/bin/env python3
"""Coverage contract tests for the js-framework benchmark fixture."""

from __future__ import annotations

from pathlib import Path
import json
import sys
import tempfile
import tomllib
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test as test_driver  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "examples/_fixtures/js-framework-benchmark/benchmarks.toml"
ADAPTER = ROOT / "benchmarks/js-framework-benchmark/roc-signals-keyed"


class BenchmarkManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        with MANIFEST.open("rb") as f:
            self.manifest = tomllib.load(f)

    def test_node_wasm_work_is_owned_by_the_harness_issue(self) -> None:
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
        self.assertEqual(
            {"update_10k", "create_10k", "append_1k_to_10k", "clear_10k"},
            {case["id"] for case in operations.values() if case.get("serial_native_spec", False)},
        )
        for case in operations.values():
            if case.get("serial_native_spec", False):
                self.assertEqual(60, case["native_spec_timeout_seconds"])

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
            self.assertEqual("official_browser_adapter", scenario["availability"])
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
            self.assertEqual("official_browser_adapter", metric["availability"])

    def test_official_browser_adapter_has_build_and_metadata_contract(self) -> None:
        package = json.loads((ADAPTER / "package.json").read_text(encoding="utf-8"))
        self.assertEqual("python3 build.py", package["scripts"]["build-prod"])
        self.assertEqual("WebAssembly", package["js-framework-benchmark"]["language"])
        self.assertTrue((ADAPTER / "package-lock.json").is_file())
        self.assertTrue((ADAPTER / "index.html").is_file())
        self.assertTrue((ADAPTER / "src/main.mjs").is_file())
        self.assertTrue((ADAPTER / "build.py").is_file())

        index = (ADAPTER / "index.html").read_text(encoding="utf-8")
        self.assertIn('id="main"', index)
        self.assertIn('/css/currentStyle.css', index)
        self.assertIn('./dist/main.mjs', index)

    def test_fixture_carries_the_official_keyed_dom_contract(self) -> None:
        source = (MANIFEST.parent / "main.roc").read_text(encoding="utf-8")
        for expected in (
            'Html.class_attr("container")',
            'Html.class_attr("jumbotron")',
            'Html.class_attr("col-sm-6 smallpad")',
            'Html.class_attr("table table-hover table-striped test-data")',
            'Html.class_attr("glyphicon glyphicon-remove")',
            'Html.class_attr("preloadicon glyphicon glyphicon-remove")',
            'Html.attr("aria-hidden", "true")',
            'Html.attr("id", "tbody")',
            'Signal.select(selected, key)',
            'Ui.each(rows, |row| row.id.to_str()',
        ):
            self.assertIn(expected, source)

    def test_test_driver_consumes_the_manifest(self) -> None:
        example = next(item for item in test_driver.load_examples() if item.slug == "js-framework-benchmark")
        cases = test_driver.load_benchmark_cases(example, ROOT)
        self.assertIsNotNone(cases)
        self.assertEqual(9, len(cases or ()))

    def test_benchmark_platform_pair_differs_only_by_instrumentation_exports_and_host(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = root / "host.o"
            host.write_bytes(b"benchmark host marker")
            production = root / "production"
            diagnostic = root / "diagnostic"
            test_driver.prepare_wasm_benchmark_platform(production, host, instrumented=False)
            test_driver.prepare_wasm_benchmark_platform(diagnostic, host, instrumented=True)

            production_manifest = (production / "main.roc").read_text(encoding="utf-8")
            diagnostic_manifest = (diagnostic / "main.roc").read_text(encoding="utf-8")
            metric_exports = (
                "roc_ui_benchmark_metrics_checkpoint",
                "roc_ui_benchmark_metrics_len",
                "roc_ui_benchmark_metrics_ptr",
                "roc_ui_benchmark_metrics_reset",
                "roc_ui_benchmark_metrics_schema_version",
            )
            for name in metric_exports:
                self.assertNotIn(name, production_manifest)
                self.assertEqual(1, diagnostic_manifest.count(name))
            stripped = diagnostic_manifest
            for name in metric_exports:
                stripped = stripped.replace(f'\t\t\t\t"{name}",\n', "")
            self.assertEqual(production_manifest, stripped)
            self.assertEqual(host.read_bytes(), (production / "targets" / "wasm32" / "host.wasm").read_bytes())
            self.assertEqual(host.read_bytes(), (diagnostic / "targets" / "wasm32" / "host.wasm").read_bytes())


if __name__ == "__main__":
    unittest.main()
