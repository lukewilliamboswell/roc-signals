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
