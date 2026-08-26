# Gallery rebuild — wave 1 findings

Five examples landed: `spreadsheet-lite`, `log-viewer`, `split-the-bill`,
`kanban-board`, `markdown-editor`. Native suite exits 0, wasm suite exits 0, all
five mount in Chrome.

## Chrome smoke results

| Example | Mounts | Interaction verified | Console |
| --- | --- | --- | --- |
| kanban-board | yes | cross-column move; untouched columns kept every a11y node id | clean |
| split-the-bill | yes | amount edit re-derived balances + settlement; invalid input → $0.00, `Balances check: $0.00` held | clean |
| log-viewer | yes | interval streaming live | clean |
| markdown-editor | yes | word count 147→148 while heading count stayed 5 (equality cutoff) | clean |
| spreadsheet-lite | yes | B2 1200→1000 propagated D2 2500→2300, D5 4100→3900, D7 4510→4290 | **host error** |

## P1 — wasm host throws on focus (browser only, native suite cannot see it)

Minimal repro: open `examples/spreadsheet-lite/` and focus any cell input. No
typing, no blur required.

```
Uncaught Error: dynamic render command referenced an empty dynamic buffer
```

Thrown at `www/static/signals.mjs:1320` in `readDynamicBytes`:
`roc_ui_dynamic_buffer_ptr()` returns 0 while a render command claims a
non-zero-length slice out of it.

This path exists only in the wasm JS host, which is why the native spec suite is
green on the identical interaction. Two consequences:

1. The native suite is not a sufficient gate for browser correctness.
2. Any example with a focusable controlled input may be affected; only
   `spreadsheet-lite` triggered it here, likely because it has 96 of them.

## P1 — `Signal.combine` is unusable for independently created signals — FIXED

Confirmed by source inspection and independently reproduced by four agents.

`platform/Signal.roc` builds `input_cap` from `signals.first().cap` and decodes
*every* element through it, but each `Signal.map` / `Ui.state` mints a fresh
`Capability.new()`. Combining signals from different call sites aborts with:

```
HOST ERROR: HostValue operation used a capability that does not own the retained value
```

It only works when every input literally shares one capability instance. This is
why `combine` had zero uses across the whole gallery — it appears never to have
worked in the case it exists for. Suggested fix: store a per-input capability
list rather than reusing the first.

Note a sharp edge in the workaround: a record-builder `.Signal` whose fields all
have the same type lowers to `combine` and hits the same error. Mixed-type
record builders and nested `map2` are safe.

## P2 — capability errors from nested / row-local signal shapes

Probably the same root cause as the above.

- A nested `Ui.each_str` over an outer-scope signal, rendered inside an
  `each_str` row, fails with the same capability error the first time the outer
  list changes.
- Row-local `Ui.state` inside an `each_str` row that *also* derives from the
  row's item signal corrupts capabilities; with a `Ui.when` on the row state it
  instead panics with `when read extension capability did not match its signal
  value`. `deployment-queue` has row-local state but never touches its row item
  signal, which is why it does not hit this.

Worth investigating as one capability-lifetime defect rather than three bugs.

## P2 — spec runner does not unescape `fill` / `change` / `select_option`

`src/spec/spec_parser.zig` uses `allocator.dupe` for these and for the
`expect_*` text values, while task payloads and `custom_event` use
`dupeUnescapedQuoted`. So `fill label:"X" "a\nb"` inserts a literal backslash-n.

Live consequence: `examples/_fixtures/markdown-elem/spec.txt:34` uses `\n` inside
a `fill` and is therefore asserting against literal backslashes today.

## P2 — metric semantics do not match the guide

- `nodes_recomputed` is 1 for every edit regardless of graph depth. It appears to
  count root record recomputes rather than derived-node work, so it is not the
  fine-grained budget metric the guide implies. `rows_reused`, `rows_created`
  and `set_value` are the metrics that actually discriminate; the performance
  section of the guide should say so.
- `bind_event` does not scale with the changed set: in `spreadsheet-lite` an edit
  dirtying five rows refreshes all 96 cell bindings, while an edit dirtying one
  or two rows refreshes none. That non-monotonicity looks like a threshold bug.
- `patches_emitted` runs well above the number of changed text sinks
  (27 vs ~13 in `split-the-bill`); suspected event rebinds on reused rows.

## P3 — expressiveness gaps that shaped every app

These are not bugs, but they constrained all five designs and are worth a
decision:

- **Reducers cannot read another state handle.** Any action needing two facts
  from two states forces those states to merge. This is why `spreadsheet-lite`
  has no "commit formula bar to selected cell" button, and why drafts have to
  live inside the collection state they belong to.
- **Intervals cannot write to `Ui.state`.** `Ui.on_change` yields only a
  `Node.Cmd`; there is no dispatch-to-state command. Timer-driven data must be
  derived from the tick count, and "clear" has to be modelled as a branch swap
  that disposes and remounts a scope.

Together these mean the write path is markedly more constrained than the read
path.

## P3 — the static-edge finding

`spreadsheet-lite` was chosen to showcase a user-authored dependency graph. It
cannot do that: signal edges are declared once by `map`/`map2`/`each_str` and
cannot be created from runtime data. Expressing a real per-cell graph would need
`combine` over a dependency set computed at runtime, which the descriptor model
cannot represent.

What it demonstrates instead is fine-grained *rendering*: evaluation is one
`Signal.map` over the whole workbook, while keyed rows and cells with `is_eq`
cutoffs scope the DOM work. Editing `B2` (5 dependent rows) vs `C12` (none):

| metric | edit B2 | edit C12 | whole sheet |
| --- | --- | --- | --- |
| `rows_reused` | 52 | 20 | 108 |
| `set_value` | 9 | 2 | 96 |

The catalogue entry for A4 should be reworded accordingly.

## Toolchain notes

- Every agent worktree was cut from `main` rather than the working branch, so
  each one opened on a red baseline (`incorrect alignment` on every pre-existing
  spec) and lost time before spotting it. A host-side ABI/version guard would
  turn that into an immediate, legible error.
- `scripts/serve.py` fails on this machine at the Tailwind step: tailwindcss
  v4.3.2 rejects `bg-zinc-50` with "Cannot apply unknown utility class". Use
  `--skip-tailwind`. Pre-existing and unrelated to the gallery work.
- Running a spec file with no executable commands segfaults the native host
  instead of reporting an error.
- Missing from the Roc surface, worked around repeatedly: `List.walk`,
  `List.reverse`, `Str.to_lowercase`, and `U64`↔`I64` conversions.


---

# Corrections and fixes applied

## Retracted: there is no silent-render bug

Three separate reports (mine included) claimed that an inline closure over a
`Ui.state` signal "compiled cleanly but rendered no text node at all". That was
a misdiagnosis in every case.

The real cause: **an unannotated numeric literal in `Ui.state` infers as a
`Frac`**, so `Ui.state(0, ...)` plus `count.to_str()` renders `"0.0"`, not
`"0"`. Because specs locate elements by exact text, the element then appears
*absent* rather than wrong, which reads exactly like a missing text node.

Verified: an unannotated `Ui.state(0, |n| ...)` with an inline closure renders
`"Count: 0.0"`. Annotating the transform (`f : U64 -> Str`) pins the literal and
it renders `"Count: 0"`. Hoisting the closure "fixed" it only because the
hoisted function carried a type annotation.

This is a genuine footgun worth documenting in the guide, but it is not a
platform bug. The misleading comment in `examples/status-page/app.roc` has been
corrected.

## Retracted: the empty-lambda-set trap is already fixed

`repro/empty-lambda-set-boxed-closure` passes on the current branch — it mounts
and clicks the first link without trapping. Commit 919560c ("Fix unit event
payload ABI") resolved it, which is consistent with the original crash firing on
first event dispatch. Earlier references in this document to that trap as an
active cause were wrong.

## Retracted: the empty-spec segfault

Not reproducible on the current branch. A spec file containing only comments,
and a zero-byte spec file, both exit 0; a missing file reports
`Error: Test spec file not found` and exits 1. The original report came from a
stale worktree.

## Fixed: `Signal.combine` per-input capabilities

`platform/Signal.roc` now keeps a capability per input signal and reads each
element back through the capability that stored it, instead of reading every
element through `signals.first().cap`.

Regression test: `examples/_fixtures/signal-combine-caps/`, which combines two
signals derived from two separate `Ui.state` handles. It fails on the old code
with `HOST ERROR: HostValue operation used a capability that does not own the
retained value` and passes now.

## Fixed: spec values are unescaped consistently

`src/spec/spec_parser.zig` used `allocator.dupe` for `fill`, `change`,
`select_option`, `key_down`, `expect_text`, `expect_value` and `expect_attr`
values while task and `custom_event` payloads went through
`dupeUnescapedQuoted`. All of them now unescape.

Consequence, as expected: `examples/_fixtures/markdown-elem/spec.txt` had been
asserting against literal backslash-n. With real newlines the document parses
into separate blocks and the link moved from segment `s:5` to `s:0`; the fixture
is updated and now genuinely exercises multi-line markdown.

## Fixed: `expect_text` falls back to descendant text

`expect_text` read only an element's own `text` field, so a container whose
content comes from signal-backed text children asserted as `""`. It now falls
back to the depth-first concatenation of descendant text when the element has no
text of its own.

This is additive — an element *with* its own text is compared exactly as before,
and no existing spec asserted `""` on a container. It removes the constraint
that forced every dynamic text line in an app to be globally unique so it could
be located by content, which had been distorting the example apps themselves.

Regression assertion added to `examples/_fixtures/signal-combine-caps/spec.txt`.

## Still open

- The wasm-host `dynamic render command referenced an empty dynamic buffer`
  error on focusing a `spreadsheet-lite` cell (`www/static/signals.mjs:1320`).
- The row-local `Ui.state` + item-signal-read crash
  (`text read extension capability did not match its signal value`).
- `Ui.when` whose true arm is `Ui.each_str` leaving rows in the DOM when it
  flips false (reported by the data-grid agent, not yet reproduced here).
- Metric semantics: `nodes_recomputed`, `bind_event` scaling, `patches_emitted`
  surplus.
- Expressiveness: reducers cannot read another state handle; intervals cannot
  write state.
