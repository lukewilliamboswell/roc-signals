# Gallery visual polish — findings log

Running log from the pass that brought every gallery example up to a shared
visual bar. Platform friction and cross-cutting bugs go here; per-example
notes stay in the commits.

## Platform bugs

### P1 — `Html.aria_invalid_s` set `aria-invalid=""`, which reads as *valid* — FIXED

`aria_invalid_s` was implemented as `bool_attr_s("aria-invalid", signal)`. The
host lowers a true boolean custom attr to `set_attr_text` with an empty value,
so the DOM ended up with `aria-invalid=""`.

`aria-invalid` is an *enumerated* ARIA attribute, not an HTML boolean one. An
empty value is not "present therefore true" — it maps to the default, `false`.
So every form example in the gallery was announcing invalid fields as valid,
and no CSS could select the invalid state either.

Fixed in `platform/Html.roc` by routing it through `attr_maybe_s`, so a true
flag sets the literal `"true"` and a false flag removes the attribute. The
`""` value was baked into three form-builder specs, the shared
form-validation fixture, and two docs pages; all updated to `"true"`.

Worth auditing whether any *other* enumerated ARIA attribute is reachable
through `bool_attr_s`, since the same trap applies to `aria-expanded`,
`aria-pressed`, `aria-checked`, and `aria-selected`.

### P0 — `Json.parser_camel()` corrupts long field names on wasm32

The Conduit feed renders "Response was not valid JSON" on every load in the
browser, while `/api/tags` on the same backend works. Chased to a Roc bug, not
a Conduit one.

On wasm32, `Json.parser_camel()` reads one byte of the field name it is looking
for out of uninitialised memory. Any field whose **camelCase form is longer
than 10 bytes** can never match:

```
{"abcdefgHij":1}    -> ok                       # 10 bytes
{"abcdefghIjk":1}   -> Missing 'abcdffghIjk'    # 11 bytes, index 4 e -> f
{"abcdefghijKlm":1} -> Missing 'abcdffghijKlm'  # 13 bytes
```

The corrupted byte is always index 4, and its value varies per run and per
call site. The threshold is exactly where Roc stops storing a `Str` inline, so
the name is most likely being read through the small-string representation
after it has become heap-allocated.

Native is unaffected — the full native spec suite passes on the same data —
which is why no spec caught it and why it only shows up in the browser.

`favoritesCount` is 14 bytes, so Conduit's article DTO can never decode.
Minimal repro and the full field-length table in
`repro/json-camel-long-field-name/`. Needs an upstream Roc issue; not
worked around here, because any workaround (renaming the DTO fields away from
the RealWorld spec) would make the example lie about the API it implements.

### P2 — the event-message type has no public name

Factoring a repeated control into a helper is the obvious way to keep a view
readable:

```roc
next_button : Node.Msg -> Elem
next_button = |msg| Html.button_attrs("Next step", [...], msg)
```

`platform/main.roc` exposes `[Elem, Signal, Html, Ui, Http, Browser]`, so
`import pf.Node` fails with "package module is private" and there is no
re-exported alias. The only workaround is to spell the parameter `_`, which
costs the annotation its documentation value on exactly the helpers an example
most wants to factor out.

Suggest re-exporting the message type (e.g. as `Ui.Msg` or `Html.Msg`) without
exposing the rest of `Node`.

### P3 — no visible-label or placeholder affordance on inputs

`Html.text_input_c(label, ...)` takes a label that becomes `aria-label` only;
it renders nothing. There is no `<label>` element helper at all. The result is
that the natural, obvious spelling of an input produces a bare unlabelled box,
which was the single most common visual defect across the gallery — every
example had it.

Placeholders work, but only via the escape hatch
`Html.attr("placeholder", "...")`; nothing signposts that.

Each example now draws its own caption inside a `field` wrapper. A
`Html.field(label, control)` helper, or a `placeholder` parameter on the input
constructors, would remove a whole class of defect.

### P1 — a `<select>`'s value is applied before its options have values

Every `<select>` in `flight-search` renders blank. The options are all present
and correct, and assigning `select.value = "SYD"` by hand works, so the markup
is fine — but `selectedIndex` is `-1` after mount.

The host applies `set_value` to the select before the `set_attr_text` ops that
give each `<option>` its `value`. Assigning a value that matches no option
leaves `selectedIndex` at `-1`, and nothing re-applies it once the options
become valid, so the control stays blank until the user touches it.

Either emit a select's `set_value` after its children are fully materialised,
or re-apply the pending value when an `<option>` under a controlled select
gains a value.

## Browser-only failures the native suite cannot see

This is the recurring shape of everything below, and it is the single most
useful thing in this log: **a green native suite says nothing about whether an
example works in a browser.** Three unrelated defects this pass were invisible
to specs that all passed, and one of them broke the featured example.

Something that opens each published example in a real browser and asserts it
mounts, has no console error, and reaches a non-loading state would have caught
all of them.

### flight-search double-frees its task payload on wasm32

Now that the example has a browser data source, the first result kills it:

```
roc_dealloc received a pointer that was already freed
  ptr=0x8e6f00 align=4 requested_size=169 allocated_size=169
  freed_phase=421 current_phase=421: unreachable
```

169 bytes is exactly the length of the task result string the handler returns,
so it is the payload allocation being freed twice while `parse_flights` decodes
it. The page renders the shell and then stops; no rows ever appear.

The native specs feed the same payload shape through the same decode and pass,
so this is wasm32-only — the same family as the two below and as the JSON
field-name corruption above. Nothing in the example can work around a double
free; it needs a runtime fix.

### support-inbox traps with "unreachable" when a conversation is opened

Polling works and the list populates, but clicking a conversation - which
issues the `read:<id>` task - traps the app with a bare `unreachable`.

This path was previously unreachable in a browser because the example had no
data at all, so nothing here is newly broken; it is newly *exposed*. That is
the pattern worth noting: giving these examples a data source did not create
these bugs, it revealed how much of the browser path had never been executed.

### markdown-editor traps with "unreachable" in the browser

Opening `examples/markdown-editor/` renders nothing but the host error
`unreachable` — a wasm trap during mount. All 11 native specs pass. Reproduced
on the commit before the polish work as well, so it predates this pass.

### Several examples have no data source in the browser at all

`status-page` sits at "Checking services", "Refreshes requested: 0" forever;
`support-inbox` shows "No conversations to show" and "Syncing…" forever. Their
tasks are plain `Signal.task_source` names (`check:api`, `incidents`, `inbox`,
`send`) and nothing in `www/static/example_tasks.mjs` answers them. They only
ever "worked" under the native host, where the spec script supplies results.

These are published in the gallery with `wasm = true`, so a visitor sees an app
that never loads.

## Pre-existing failures found along the way

### markdown-editor — character count off by one

Four specs assert `Characters: 821` / `827`; the app reports `822` / `828`.
Reproduced on a clean checkout of `polish-examples` with no local changes, so
it predates this work. Tracked separately.

## API friction, ranked by how often it bit

Every example in the gallery was restyled in this pass, and the same handful of
gaps came up again and again. Ordered by the number of examples that hit them.

### 1. There is no inline element (11 of 21 examples)

`Html` has `div`, `section`, `paragraph`, `pre`, `heading`, but nothing inline.
A badge beside a label, a timestamp before a message, a unit after a figure -
all of these are naturally `<span>`, and all of them have to become block `<p>`s
inside a flex container instead.

This is not only cosmetic. Because `expect-text` concatenates descendant text
with no separator, splitting a line into two block elements changes what a spec
sees, so authors were pushed toward pre-joining strings in Roc - which is
exactly what made the gallery read as sentences instead of as UI. A `span_c` /
`span_s_attrs` pair would remove the pressure at its source.

### 2. Controls cannot draw their own visible label (9 examples)

`Html.text_input_c(label, ...)`, `checkbox`, `radio`, and `select` all take a
label that becomes `aria-label` only and renders nothing. Every example
independently reimplemented the same `field` + caption wrapper, and the ones
that forgot shipped bare unlabelled boxes - the single most common defect found
at the start of this pass.

Worse, because the accessible name is what specs address (`(label "Label f1")`)
while the visible caption should read "Label", controls end up with an
`aria-label` that deliberately differs from their visible text. That is a real
accessibility smell forced by the locator vocabulary.

A `Html.field(caption, control, note)` helper, or a `checkbox_row` /
`radio_row` that draws its own caption, would fix both.

### 3. `expect-text` concatenates descendants with no separator (7 examples)

`appendDescendantText` in `src/spec/spec_runner.zig` joins with nothing, so a
test-id on a two-cell row asserts `"Chloe pays Ana$108.83"`, and a stat tile
asserts `"Matching rows1200"`. Every example resolved this by splitting one
assertion into two test-ids, which is fine, but the failure mode is an
unreadable expectation rather than an error. A separator, or an
`expect-text-joined` variant, would make composed rows testable directly.

### 4. No table elements (3 examples, but the ones that most needed them)

`data-table` and `table-scroll` exist in the design system and are unusable from
Roc: there is no `table`/`thead`/`tr`/`th`/`td`. The data grid and the
spreadsheet both hand-rebuilt the treatment on CSS grid, losing real table
semantics - no row or column headers for screen readers, no `scope`. A generic
`Html.element : Str, List(Attr), List(Elem) -> Elem` escape hatch would cover
this and every future gap of the same shape.

### 5. Only one heading level

`Html.heading_c` always emits `h2`, so an app title and a panel title are the
same level and a page has no document outline.

### 6. `Ui.state` does not compose

Seven filters means seven levels of closure nesting before any code. Examples
work around it with a `Handles` record (see the onboarding wizard), but the
rightward drift is the first thing a reader sees. A `Ui.states({...})` returning
a record of handles would remove it.

### 7. Types that cannot be named

`Node.Msg` and `Node.Attr` are what `Ui.on_unit` and `Html.attr` return, but
`pf.Node` is private and nothing re-exports them. Any helper that factors out a
repeated control - the obvious refactor in every example - has to spell its
parameter `_`.

### 8. Conditional rendering has no cheap form

`Ui.when` allocates a scope per branch, which is too expensive inside a keyed
row under a patch budget; the alternative is toggling a class to `hidden`, which
keeps the element in the DOM. Neither is right for "show this badge only when
flags > 0". A `Ui.show(signal, elem)` that patches presence without a scope
would fit. Worth documenting either way, because the trap is not obvious: *any*
per-row decoration costs patches proportional to rows changing.

### 9. Signal-backed class needs a differently-shaped helper

`Html.paragraph_s_c` takes a static class, so any element whose tone is derived
must drop to `paragraph_s_attrs([class_attr_s(...)])` and map the same source
signal twice - once for the text, once for the class. A
`paragraph_s_sc : Signal(Str), Signal(Str) -> Elem` would remove that in a dozen
places, and would make it structurally harder for a caption and its colour to
disagree.

### 10. `Ui.each_str` limitations

- No container class, so every list needs an extra wrapping `div`.
- The row callback gets `(key, Signal(item))` with no access to per-item data
  that is constant for the row's life, so a static fact has to be read through
  the item signal - turning it into a live sink - or smuggled through the key
  string. The log viewer parses its line number back out of `"line-42"`.
- **Possible bug:** the spreadsheet restyle found that mapping a second signal
  off the same source that feeds `Ui.each_str` corrupted the DOM. It rendered
  correctly at mount, but after a list update an unrelated element failed to
  resolve to one element. Deriving the second value independently fixed it. If a
  keyed-list source really does only tolerate one consumer, that should be an
  error rather than a silent miscompile - worth reproducing properly.

### 11. `Html.section` welds its label to `role="region"`

There is no way to give an element an accessible name without also making it a
landmark, so a list of ten cards becomes ten landmarks.

### 12. `Html.attr_s("style", ...)` is the only way to use a runtime value in CSS

Tailwind can only emit classes it sees at build time, so a swatch painted with a
token's colour, or a Gantt bar whose width is derived, has to go through the
generic attribute path. It works, and `expect-attr` reads it back, but nothing
signposts it. A `Html.style_s` would make it discoverable.

## Toolchain notes

- `scripts/serve.py` requires the Tailwind **v3** standalone CLI. A v3 config
  (`tailwind.config.js`, `@tailwind` directives) against a v4 `tailwindcss` on
  PATH fails with `Cannot apply unknown utility class 'bg-zinc-50'`, which does
  not point at the version mismatch. Worth pinning the expected version in
  `contributing.md` or checking `tailwindcss --help` output in `serve.py`.
- The built example binary takes a single spec **file**, not a directory.
  Passing `specs/` fails with `Error: Failed to parse test spec`, which reads
  like a malformed spec rather than a usage error. Directory walking lives in
  `scripts/spec_driver.py`.
- `scripts/test.py` shares one `.test-out/` directory, so parallel runs clobber
  each other. `scripts/dev/check-example.sh` was added for the type-check loop;
  the spec loop still needs copying into a private directory by hand.
- The dev static server should send `Cache-Control: no-store`. Chrome applied
  heuristic freshness to `.mjs` files and served stale host code for a whole
  debugging session, which made two real fixes look like they had not worked.
- `roc check examples/<slug>/main.roc` directly reports errors from the
  *released* platform in the roc cache, not the local `platform/`. Use
  `python3 scripts/test.py roc-check` instead, which rewrites the platform
  header first.
