#!/usr/bin/env python3
"""Known-failure ratchet for the example spec suites.

`test/known-failures.txt` lists every spec and wasm mount that is currently
expected to fail. The suites run to completion regardless of failures, and the
run is judged against that list at the end:

  * a failure that is not listed is a regression and fails the run;
  * a listed entry that now passes also fails the run, with an instruction to
    delete the line, so the list only ever shrinks by fixing things;
  * `--update-known-failures` removes entries that passed. It never adds one:
    a new failure has to be written into the file by hand, next to a comment
    saying why it is being accepted, where a reviewer will see it.

Entries are one per line, `native <example>/<spec>.scm` or `wasm <example>`.
Blank lines and `#` comments are ignored. Only entries whose spec actually ran
are judged, so filters and shards leave the rest of the list alone.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

KINDS = ("native", "wasm")


@dataclass(frozen=True)
class Outcome:
    key: str
    passed: bool
    detail: str = ""


@dataclass
class Ledger:
    known: frozenset[str]
    outcomes: list[Outcome] = field(default_factory=list)

    def record(self, kind: str, name: str, passed: bool, detail: str = "") -> None:
        if kind not in KINDS:
            raise ValueError(f"unknown outcome kind: {kind!r}")
        self.outcomes.append(Outcome(f"{kind} {name}", passed, detail))

    @property
    def regressions(self) -> tuple[Outcome, ...]:
        return tuple(o for o in self.outcomes if not o.passed and o.key not in self.known)

    @property
    def fixed(self) -> tuple[Outcome, ...]:
        return tuple(o for o in self.outcomes if o.passed and o.key in self.known)

    @property
    def expected_failures(self) -> tuple[Outcome, ...]:
        return tuple(o for o in self.outcomes if not o.passed and o.key in self.known)

    @property
    def clean(self) -> bool:
        return not self.regressions and not self.fixed


def parse(text: str) -> frozenset[str]:
    entries: set[str] = set()
    for line_number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        kind, _, name = line.partition(" ")
        if kind not in KINDS or not name or " " in name:
            raise ValueError(f"known-failures line {line_number}: expected '<native|wasm> <name>', got {raw!r}")
        entries.add(f"{kind} {name}")
    return frozenset(entries)


def load(path: Path) -> frozenset[str]:
    if not path.exists():
        return frozenset()
    return parse(path.read_text())


def report(ledger: Ledger, path: Path) -> int:
    """Prints the ratchet summary and returns the process exit status."""
    total = len(ledger.outcomes)
    passed = sum(o.passed for o in ledger.outcomes)
    print(f"\n=== known-failure ratchet ({path}) ===")
    print(
        f"{passed} passed, {len(ledger.expected_failures)} known failing, "
        f"{len(ledger.fixed)} fixed, {len(ledger.regressions)} regressed, {total} total"
    )
    for outcome in ledger.regressions:
        print(f"  REGRESSION  {outcome.key}" + (f" — {outcome.detail}" if outcome.detail else ""))
    for outcome in ledger.fixed:
        print(f"  FIXED       {outcome.key}")
    if ledger.regressions:
        print(
            "\nRegressions must be fixed. Accepting one means adding its line to"
            f" {path} by hand, with a comment explaining why."
        )
    if ledger.fixed:
        print(
            f"\nFixed entries must be removed from {path} so they cannot regress"
            " silently: python3 scripts/test.py ... --update-known-failures"
        )
    return 0 if ledger.clean else 1


def remove_fixed(path: Path, ledger: Ledger) -> int:
    """Deletes the lines for entries that passed, keeping comments and order."""
    fixed = {o.key for o in ledger.fixed}
    if not fixed:
        return 0
    kept: list[str] = []
    removed = 0
    for raw in path.read_text().splitlines():
        entry = raw.split("#", 1)[0].strip()
        if entry in fixed:
            removed += 1
            continue
        kept.append(raw)
    path.write_text("\n".join(kept).rstrip("\n") + "\n")
    return removed
