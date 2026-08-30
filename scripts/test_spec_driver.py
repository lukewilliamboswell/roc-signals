#!/usr/bin/env python3
"""Contract tests for the native spec directory driver."""

from __future__ import annotations

from pathlib import Path
import stat
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spec_driver  # noqa: E402
import test as test_driver  # noqa: E402


class SpecDriverTests(unittest.TestCase):
    def test_discovery_filtering_and_sharding_are_stable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ("z.scm", "nested/b.scm", "nested/a.scm"):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("(test \"fixture\" (steps (mark-metrics)))\n", encoding="utf-8")
            (root / "ignored.spec").write_text("legacy", encoding="utf-8")

            cases = spec_driver.discover_specs(root)
            self.assertEqual(
                ["nested/a.scm", "nested/b.scm", "z.scm"],
                [case.id for case in cases],
            )
            selected = spec_driver.select_specs(cases, patterns=("nested/*",), shard=(1, 2))
            self.assertEqual(["nested/b.scm"], [case.id for case in selected])

    def test_worker_results_and_protocol_errors_are_classified(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            spec = root / "case.scm"
            spec.write_text("(test \"case\" (steps (mark-metrics)))\n", encoding="utf-8")
            worker = root / "worker"
            worker.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import json
                    print(json.dumps({{
                        "protocol": {spec_driver.PROTOCOL!r},
                        "id": "ignored",
                        "name": "case",
                        "status": "passed",
                        "duration_ns": 42,
                        "failure": None,
                    }}))
                    """
                ),
                encoding="utf-8",
            )
            worker.chmod(worker.stat().st_mode | stat.S_IXUSR)

            result = spec_driver.run_case(
                worker,
                spec_driver.SpecCase("case.scm", spec),
                timeout_seconds=1,
                verbose=False,
            )
            self.assertTrue(result.passed)
            self.assertEqual(42, result.duration_ns)

            worker.write_text("#!/usr/bin/env python3\nprint('not json')\n", encoding="utf-8")
            invalid = spec_driver.run_case(
                worker,
                spec_driver.SpecCase("case.scm", spec),
                timeout_seconds=1,
                verbose=False,
            )
            self.assertEqual("protocol_error", invalid.status)
            self.assertEqual("invalid_json", invalid.failure["kind"])

    def test_native_driver_skips_examples_without_filter_matches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            (first / "unrelated.scm").write_text("(test \"first\" (steps (mark-metrics)))\n", encoding="utf-8")
            (second / "target.scm").write_text("(test \"second\" (steps (mark-metrics)))\n", encoding="utf-8")

            first_selected = test_driver.select_native_specs(first, patterns=("*target.scm",))
            second_selected = test_driver.select_native_specs(second, patterns=("*target.scm",))
            self.assertEqual((), first_selected)
            self.assertEqual(["target.scm"], [case.id for case in second_selected])

    def test_fault_campaign_expands_clean_allocation_count_into_isolated_workers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            specs = root / "specs"
            specs.mkdir()
            (specs / "case.scm").write_text('(test "case" (steps (mark-metrics)))\n', encoding="utf-8")
            worker = root / "worker"
            worker.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import json
                    import sys
                    allocation = int(sys.argv[sys.argv.index("--fail-on-allocation") + 1]) if "--fail-on-allocation" in sys.argv else None
                    print(json.dumps({{
                        "protocol": {spec_driver.PROTOCOL!r},
                        "id": "case.scm",
                        "name": "case",
                        "status": "passed",
                        "duration_ns": 1,
                        "failure": None,
                        "host_allocation_attempts": 2,
                        "fault": None if allocation is None else {{
                            "allocation": allocation,
                            "outcome": "refused_then_retried",
                        }},
                    }}))
                    """
                ),
                encoding="utf-8",
            )
            worker.chmod(worker.stat().st_mode | stat.S_IXUSR)

            results = spec_driver.run_fault_suite(worker, specs, jobs=2)
            self.assertEqual(3, len(results))
            self.assertTrue(all(result.passed for result in results))
            self.assertEqual(
                ["case.scm", "case.scm::allocation@1", "case.scm::allocation@2"],
                [result.id for result in results],
            )


if __name__ == "__main__":
    unittest.main()
