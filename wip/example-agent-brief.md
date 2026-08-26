# Brief: building a Roc Signals gallery example

You are building ONE new example app for the Roc Signals gallery. First pass:
**correctness, interaction, and a comprehensive spec** — NOT styling.

## FIRST: make sure your worktree is current

A git worktree is a checkout, so it only has committed state. Before anything
else, bring your worktree up to the working branch:

```sh
git merge pin-roc-nightly-2026-08-13   # or rebase onto it
zig build
```

Confirm before you report any platform bug:

```sh
diff -r /home/lbw/Documents/Github/roc-signals/platform platform
```

If that diff is non-empty your platform is stale and you will "discover" bugs
that are already fixed. Never report a platform bug without running it first.

## Toolchain

```sh
export ROC_BIN=/home/lbw/roc_nightly-linux_x86_64-2026-08-25-cc03aa8/roc
python3 scripts/test.py roc-check --roc-bin $ROC_BIN     # fast type-check loop
python3 scripts/test.py native   --roc-bin $ROC_BIN      # builds + runs all native specs
```

`roc-check` is your inner loop; it takes seconds. Run `native` to actually execute
your spec. Note `native` builds every example in the manifest, so expect minutes.

## Files you own

Create `examples/<slug>/` containing:

- `app.roc` — the app. Split into modules (`Foo.roc`) if it exceeds ~400 lines.
- `spec.txt` — the native semantic spec (see below).

Add an entry to `www/data/examples.toml` so the runner picks your example up:

```toml
[[examples]]
slug = "<slug>"
title = "<Title>"
description = "<one sentence>"
source = "examples/<slug>/app.roc"
spec = "examples/<slug>/spec.txt"
public = true
wasm = true
native = true
bench = true
```

Do NOT touch any other example's files. Do NOT edit `platform/` or `src/`.
If you believe the platform has a bug or a missing capability, work around it and
report it in your final message — do not change the platform.

## Study these first

- `www/content/docs/guide.md` — the programming model. Read it fully.
- `www/content/docs/contributing.md` §"Spec Language" — the complete spec vocabulary.
- `examples/live-search/` — best reference for async, intervals, cleanup, specs.
- `examples/service-ops-center/` — best reference for multi-module structure,
  routing, components.
- `platform/Signal.roc`, `platform/Ui.roc`, `platform/Html.roc`, `platform/Elem.roc`,
  `platform/Browser.roc`, `platform/Http.roc` — the actual available API. Read the
  source; do not guess at function names.

## What makes these examples worth building

The existing gallery under-sells the framework: `Signal.map2` and `Signal.combine`
are used zero times across all eleven examples, and one app is 1010 lines behind a
single `Ui.state`. Your example exists to fix that. Specifically:

- **Decompose state.** Prefer several small `Ui.state` handles over one god-record.
- **Derive, don't store.** Anything computable from other state must be a derived
  signal (`Signal.map`, `map2`, `combine`), never a field kept in sync by hand.
- **Show the graph.** Aim for at least one genuine fan-in (two or more independent
  signals feeding one derived value) and one chain two or more hops deep.

## Spec requirements (this is the main deliverable)

The spec is a first-class artifact, not an afterthought. It must:

1. Assert the **initial** rendered state completely — every region, heading, and
   derived value the app shows on mount.
2. Drive every **interaction** the app supports, asserting the resulting state
   after each one.
3. Cover **edge cases**: empty collections, a single item, invalid input,
   boundary values, and error paths.
4. Where the app is async: cover loading, success, failure, cancellation, and a
   stale result arriving after a newer request (`resolve_stale_task`).
5. Where the app has a list: cover add, remove, reorder, and per-row edits, and
   assert that editing one row does not disturb its siblings.
6. Include at least one `mark_metrics` / `expect_metric_delta` pair proving
   fine-grained updates — e.g. that editing one row does not recreate every row
   (`rows_created`, `rows_reused`, `nodes_recomputed`, `patches_emitted`).
   Determine the true value by running the spec and reading the reported actual;
   never invent a number, but do sanity-check that the number you record is the
   one a fine-grained engine *should* produce. If it is not, that is a finding —
   report it.

Locators are semantic (`role:`/`label:`/`test_id:`/`text:`), so give every
interactive element a real accessible name and every region a `role` + name. This
is a correctness requirement, not a styling one.

**Do not locate dynamic text by its content.** `expect_text text:"X" "X"` uses
the same string as both locator and expectation: it only proves an element with
that text exists, it cannot report a value mismatch, and when the value changes
it fails with "no element has text ..." — which is very easily misread as "the
text did not render". Put a `test_id` on dynamic text instead:

```roc
Html.paragraph_s_attrs(status, [Html.test_id("sync-status")])
```

```txt
expect_text test_id:"sync-status" "Synced 3 notes"
```

`Html.paragraph_s_attrs` exists for exactly this. Use `text:` locators only for
static content.

**Metric assertions:** assert `rows_created` / `rows_reused` / `rows_removed` /
`scopes_created` / `scopes_disposed` exactly — they are semantic. Bound
`patches_emitted` with `expect_metric_delta_at_most`; its precise value moves
with unrelated engine changes.

Do NOT use `nodes_recomputed` as a fine-grained budget. It counts dirty source
roots — one per event dispatch — so it is 1 for almost every interaction no
matter how deep the graph. Use `derived_calls_into_roc` (one per
`map`/`map2`/`combine` evaluation, plus one for the dispatch) and
`propagation_prunes` (equality cutoffs that fired). See
`examples/_fixtures/metric-semantics/`.

## Accessibility and markup

Use semantic roles and labels throughout — headings, regions, lists, buttons with
real names, inputs with real labels. The spec depends on it and so do real users.

## Done means

- `python3 scripts/test.py roc-check --roc-bin $ROC_BIN` is clean.
- `python3 scripts/test.py native --roc-bin $ROC_BIN` passes, including your spec.
- Your spec meets all six requirements above.
- You have NOT modified another example, the platform, or `src/`.

## Final message

Report, concisely:
- what the app does and how state is decomposed,
- which signal-graph shapes it demonstrates (name the fan-ins and chains),
- your spec's coverage and the metric assertions you landed,
- anything that surprised you, that the platform made hard, or that looks like a
  platform bug.

Do not report success unless the native suite actually passed. If you could not
get it green, say exactly what fails.

## Reading another state handle in a reducer

A reducer can read a second state handle atomically with `on_unit_with`,
`on_str_with`, `on_bool_with`, `on_detail_with` and `on_key_with`:

```roc
# update `sheet` using the current value of `cursor`
sheet.on_str_with(cursor, |sheet_value, cursor_value, text| ...)
```

This removes the constraint that used to force unrelated state into one record
just because a single action needed both. Prefer several small handles plus a
`*_with` reducer over a god-record. `examples/spreadsheet-lite` edits the
selected cell through the formula bar this way, and
`examples/_fixtures/state-reads/` is the minimal case.

Several earlier examples merged state for exactly this reason and have not been
revisited; do not copy that pattern.

## Known platform traps (read before you design)

These were found by earlier agents and confirmed. Design around them; do not try
to fix them.

### `Signal.combine` works now — earlier examples avoid it

`Signal.combine` used to read every input through the first signal's capability
and aborted at runtime when the inputs came from different call sites. That is
FIXED (`platform/Signal.roc`), with a regression test at
`examples/_fixtures/signal-combine-caps/`.

Earlier gallery examples avoid `combine` and use nested `Signal.map2` or a
record-builder `.Signal`. Both remain fine. Use whichever reads best — for a
wide fan-in over same-shaped inputs, `combine` is now the clearer choice.

### Row-local `Ui.state` inside `Ui.each_str` is shape-sensitive

Putting a `Ui.state` inside an `each_str` row renderer works in some apps
(`examples/deployment-queue` does it) but crashes at mount with
`Roc crashed: runtime error` in others, even with a near-identical row renderer.
(The empty-lambda-set issue in `repro/` is fixed and is NOT the cause.)

If you need per-row state, try it early — do not build your whole app on the
assumption that it works. If it crashes, prefer lifting the state up (keep a
per-row field in the parent's collection) and report the shape that failed.

### Writing state from a signal change: use `State.set_cmd`

`Ui.on_change` / `Ui.on_change_initial` yield a `Node.Cmd`, and `State.set_cmd`
turns a value into one:

```roc
Ui.on_change(ticks, |n| elapsed.set_cmd(n))
```

So an interval or a task result CAN push into retained state. Earlier examples
predate this and derive timer data from the tick count instead — that is still
a fine shape, but it is no longer forced. See
`examples/_fixtures/state-commands/`.

### Unannotated number literals in `Ui.state` infer as `Frac`

`Ui.state(0, |n| ...)` with no type annotation anywhere infers a **`Frac`**, so
`n.to_str()` renders `"0.0"`, not `"0"`. Because specs locate elements by exact
text, the element then looks *absent* and it is very easy to misread this as
"the text did not render".

Three agents lost time to exactly this. Annotate the transform
(`label : U64 -> Str`) or the state, and if an assertion mysteriously cannot
find an element, dump what actually rendered first:

```txt
expect_text role:region name:"Your Region" "PROBE"
```

That now reports the concatenated descendant text of the region, which shows you
the real value.

### Your worktree may not be on the right commit

Before you do anything else, run `git log --oneline -3` and confirm you are on
the same commit as the primary repo at /home/lbw/Documents/Github/roc-signals
(check with `git -C /home/lbw/Documents/Github/roc-signals log --oneline -1`).
If you are not, the platform under you is stale and unmodified examples will
appear to crash. Do not report those as findings — rebase or develop against the
primary repo's `platform/` directory, and say so in your final message.

## Also required: the wasm gate

`python3 scripts/test.py native` is NOT sufficient. The wasm JS host has code
paths the native host does not, and a bug has already been found that the native
suite cannot see. Before you report done, also run:

```sh
python3 scripts/test.py wasm --roc-bin $ROC_BIN
```

and confirm your example reports `mounted <your-slug>`.
