# Brief: polishing a Roc Signals gallery example

You are restyling ONE existing example so it reads as a real product screen
rather than a debug dump. The app's *behaviour* is already correct and covered
by native specs. Your job is the view layer.

Read `examples/onboarding-wizard/main.roc` first. It is the worked reference
for every pattern below.

## Hard rules

- Touch only `examples/<your-slug>/**`. Do NOT edit `www/input.css`,
  `platform/**`, `src/**`, or any other example.
- Keep every `Html.test_id(...)` and `data-*` attribute. Native specs address
  the DOM through those, and a rename silently breaks a spec you cannot see.
- You MAY change what an element *says*, and update the specs to match. Many
  of these examples render metrics as whole sentences ("Board total: 5 cards")
  purely because a spec asserts that sentence. A status page shows a badge, not
  a sentence, so move the test-id onto the badge and rewrite the assertion to
  the badge's text.

  What you must NOT do is keep the sentence alive in a hidden element beside
  the real UI. `sr-only` duplicate text, `text-[0px]` with `before:content`,
  and label/value pairs glued together with a load-bearing leading space are
  all worse than editing the spec: they ship dead text to screen-reader users
  and leave a trap for the next person. Change the view, then change the spec,
  and say in the commit why the assertion moved.

  Work-budget assertions (`expect-metric-delta`, `expect-metric-delta-at-most`)
  may be raised when your change genuinely derives or patches more, but say
  what the extra work is in a comment above the number. Never raise one to
  paper over a re-render you did not intend.
- Do NOT change reducers, signal wiring, or derived values, except where this
  brief explicitly calls for it (empty states, validation tone, placeholders).
- Keep the comments that explain the signal model. They are the point of the
  example. Update one only if your change makes it inaccurate.
- Follow `style.md` for Roc style. Annotate new top-level helpers.

## Toolchain

```sh
export ROC_BIN=/home/lbw/roc_nightly-linux_x86_64-2026-08-26-b29bef3/roc
scripts/dev/check-example.sh <your-slug>
```

That is your inner loop; it takes a second or two and it must report "No
errors found" before you report done. It checks only your example, in a
private scratch directory, so it is safe to run while other agents work.

Do NOT run `scripts/test.py` — it shares one output directory and parallel
runs clobber each other. The orchestrator runs the full native suite.

You cannot run a browser. The orchestrator does the visual pass and will come
back to you with screenshots if something is off.

## The design system

These classes are defined in `www/input.css` and are shared by every example.
Use them instead of inventing per-example utility soup. Tailwind utilities are
still right for *layout* (`grid`, `gap-*`, `flex`, `sm:grid-cols-*`, `min-w-0`).

Shell and header
- `app-shell` — root element of the app. Adds the centred measure and padding.
  Add `app-shell-narrow` for single-column form apps, `app-shell-wide` for
  dense/tabular apps that need the room. Plain `app-shell` otherwise.
- `app-header` / `app-title` / `app-subtitle` — the title block. This is a
  header, NOT a panel: do not wrap it in `panel`.

Surfaces
- `panel` — the standard card surface (border + white + shadow). Pair with
  your own padding, e.g. `panel grid gap-4 p-5`.
- `panel-head` / `panel-title` / `panel-body` — for panels with a header strip.
- `panel-title` on its own is the small uppercase section eyebrow.
- `card` / `card-title` — a repeated item inside a panel (list rows, tiles).
- `toolbar` — a row of controls, `flex flex-wrap items-end gap-3`.
- `empty-state` — the dashed box shown when a list has nothing in it.

Type
- `app-title`, `panel-title`, `card-title`
- `value` (emphasised body), `muted` (secondary body), `hint` (small caption)
- `numeric` — tabular figures. Put it on ANY number that changes, so digits
  do not jitter as values update.

Metrics
- `stat-grid` > `stat` > (`stat-label`, `stat-value`). Use this for the
  "N cards / N matching / N over limit" style summaries that currently render
  as a stack of sentences. A metric is a label and a number, not a sentence.

Badges — `badge` plus one of `badge-neutral`, `badge-ok`, `badge-warn`,
`badge-danger`, `badge-info`. Use for status words (Done, Failed, Syncing,
Over limit) that are currently plain text.

Controls
- `field` > (`field-label`, control, note) — the standard labelled control.
- `input` — every text/number/select/textarea. Add `textarea` alongside for
  multi-line. It carries its own focus ring and invalid state.
- `checkbox` and `check-row` for checkbox/radio lines.
- `button`, `button-primary`, `button-ghost`, `button-danger`, `button-sm`.
  Exactly one `button-primary` per view — the main action.

Notices — `notice` plus `notice-error`, `notice-ok`, `notice-warn`,
`notice-info`. For inline result/error banners.

Tables — `data-table` (with real `th`/`td`), wrapped in `table-scroll` when it
can overflow.

## What "polished" means here

1. **The app has a measure.** Root is `app-shell`. Nothing is edge-to-edge.
2. **Every control has a visible label.** `Html.text_input_c`'s first argument
   is only an *accessible* label — it renders nothing. A bare box with no
   caption is the single most common defect. Wrap it in `field` and draw a
   `field-label`, and add a `Html.attr("placeholder", "...")` with a realistic
   example value.
3. **Numbers are metrics, not prose.** Replace stacked sentences like
   `Count: 2` / `Matching: 2` with a `stat-grid`.
4. **Status words are badges**, coloured by meaning.
5. **Empty lists say so** with `empty-state`, rather than rendering nothing.
6. **Actions are grouped and ranked.** Related buttons sit in one row; the
   primary action is visually primary and sits at the end of the flow.
7. **Content is realistic.** Seed data should look like a real workspace, not
   `foo`/`bar`/`Item 1`. Placeholder text shows a plausible value.
8. **Validation has tone.** A message on an untouched field is a neutral
   `hint`; it only turns red once there is input that cannot be accepted. See
   `note_tone` in the reference example.
9. **It survives 1440px and 768px.** Use responsive column counts; let wide
   tables scroll inside `table-scroll`, never the page.

## Report back

Finish with a short report: what you changed, anything you could not do, and —
separately — any *platform* friction you hit (a missing Html helper, an API
that forced an awkward shape, a value you could not derive). Do not fix the
platform yourself; just describe it precisely.
