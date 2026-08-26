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


if __name__ == "__main__":
    unittest.main()
