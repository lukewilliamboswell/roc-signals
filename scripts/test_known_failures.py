#!/usr/bin/env python3
"""Contract tests for the known-failure ratchet."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import known_failures  # noqa: E402


class ParseTests(unittest.TestCase):
    def test_parses_entries_and_ignores_comments(self) -> None:
        entries = known_failures.parse("# header\n\nnative a/b.scm  # why\nwasm c\n")
        self.assertEqual(entries, frozenset({"native a/b.scm", "wasm c"}))

    def test_rejects_malformed_lines(self) -> None:
        for text in ("bogus a/b.scm", "native", "native a b"):
            with self.assertRaises(ValueError):
                known_failures.parse(text)


class LedgerTests(unittest.TestCase):
    def ledger(self) -> known_failures.Ledger:
        return known_failures.Ledger(known=frozenset({"native ex/old.scm", "wasm broken"}))

    def test_known_failure_is_expected(self) -> None:
        ledger = self.ledger()
        ledger.record("native", "ex/old.scm", False)
        self.assertTrue(ledger.clean)
        self.assertEqual(len(ledger.expected_failures), 1)

    def test_new_failure_is_a_regression(self) -> None:
        ledger = self.ledger()
        ledger.record("native", "ex/new.scm", False, "trap")
        self.assertFalse(ledger.clean)
        self.assertEqual([o.key for o in ledger.regressions], ["native ex/new.scm"])

    def test_unexpected_pass_is_flagged(self) -> None:
        ledger = self.ledger()
        ledger.record("wasm", "broken", True)
        self.assertFalse(ledger.clean)
        self.assertEqual([o.key for o in ledger.fixed], ["wasm broken"])

    def test_unrun_entries_are_not_judged(self) -> None:
        ledger = self.ledger()
        ledger.record("native", "ex/other.scm", True)
        self.assertTrue(ledger.clean)

    def test_report_exit_status(self) -> None:
        ledger = self.ledger()
        ledger.record("native", "ex/old.scm", False)
        self.assertEqual(known_failures.report(ledger, Path("x")), 0)
        ledger.record("native", "ex/new.scm", False)
        self.assertEqual(known_failures.report(ledger, Path("x")), 1)


class UpdateTests(unittest.TestCase):
    def test_remove_fixed_only_removes_passing_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "known-failures.txt"
            path.write_text("# keep me\nnative ex/old.scm\nnative ex/still.scm # reason\nwasm broken\n")
            ledger = known_failures.Ledger(known=known_failures.load(path))
            ledger.record("native", "ex/old.scm", True)
            ledger.record("native", "ex/still.scm", False)
            ledger.record("native", "ex/new.scm", False)
            self.assertEqual(known_failures.remove_fixed(path, ledger), 1)
            self.assertEqual(path.read_text(), "# keep me\nnative ex/still.scm # reason\nwasm broken\n")


if __name__ == "__main__":
    unittest.main()
