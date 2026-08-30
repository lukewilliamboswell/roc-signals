# Fuzz regression corpus

One directory per fuzz target, holding inputs that `python3 scripts/fuzz.py check`
replays through that target's `repro-<target>` executable. CI runs `check`, so an
input landed here is replayed on every change from then on.

A fuzzing campaign is worth only the run it happens in unless its findings
outlive it. `.fuzz-out/` — where AFL++ keeps its live corpora and crashes — is
scratch: large, machine-specific, and removed by `fuzz.py clean`. This directory
is the opposite, and is deliberately small enough to read.

## What belongs here

- **A triaged crash**, minimized with `fuzz.py minimize` and added once the bug
  behind it is fixed. This is the main case: it is the regression test.
- **A shape that took the fuzzer a long time to reach.** Coverage-discovered
  inputs that reach a deep engine state are worth keeping as seeds even when
  nothing was ever wrong with them, because they save the next campaign the
  search.
- **Degenerate inputs.** `empty`, `single-zero`, `zeros-64`, and `ones-64` exist
  for every target. They cost nothing and they catch the generator regression
  where a target stops decoding short or saturated inputs into valid programs —
  a failure that would otherwise show up as a silent loss of fuzzing depth
  rather than as a test failure.

## When an input is expected to fail

`known-failures.txt` lists inputs that currently fail, so `check` can stay green
on a bug that is understood and not yet fixed. It ratchets the same way
`test/known-failures.txt` does: an unlisted failure is a regression, and a listed
input that starts passing also fails the run, with an instruction to delete the
line, so the list only ever shrinks.

Listing an input is not a way to quiet a failure. The alternative is deleting the
input, which throws away the reproduction; keeping it listed means the bug stays
visible in every run and the fix is what removes it. Each entry needs a comment
saying which bug it belongs to, and the bug belongs in `wip/issues.md`.

## Adding one

    python3 scripts/fuzz.py minimize structural .fuzz-out/structural/out/primary/crashes/id:000000,...
    python3 scripts/fuzz.py add structural .fuzz-out/structural/minimized sibling-each-commit-trap

Names are descriptive rather than content-hashed, because the reason an input is
kept is not recoverable from its bytes.
