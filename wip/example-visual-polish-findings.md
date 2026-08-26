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

## Toolchain notes

- `scripts/serve.py` requires the Tailwind **v3** standalone CLI. A v3 config
  (`tailwind.config.js`, `@tailwind` directives) against a v4 `tailwindcss` on
  PATH fails with `Cannot apply unknown utility class 'bg-zinc-50'`, which does
  not point at the version mismatch. Worth pinning the expected version in
  `contributing.md` or checking `tailwindcss --help` output in `serve.py`.
- `roc check examples/<slug>/main.roc` directly reports errors from the
  *released* platform in the roc cache, not the local `platform/`. Use
  `python3 scripts/test.py roc-check` instead, which rewrites the platform
  header first.
