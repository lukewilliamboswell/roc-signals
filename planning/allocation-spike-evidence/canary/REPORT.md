**Result: the template cannot express the canary.** Of the 3 requirements, only the static value works. Independent per-row signal inputs, the action callback and the conditional child all stop. The same component works with ordinary `Ui.each`. The worktree was not changed (`git status --short` hash identical before and after), and I did not read `src/signals/`. My spec is only a mount check (`expect-visible (test-id "row-a")`): no clicks or list edits were exercised, so "passed" means it mounted.

**What I built**
All paths are under `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/canary/`:
- `TaskRow.roc` is the packaged module and holds the attempt verbatim, including `view`, `full_template`, the single-feature variants and `static_template`.
- `main_{ordinary,full,signal,event,when,component,static,item,keystr}.roc` each hold one site expression.
- `spec.scm` is the mount spec.
- `ann/` is the handler annotation test.
- `done_template` was written but never used or run, so the two-lists conditional workaround below is untested.

**Results** (all compile-time rejections came from `roc build`; runtime panics are SIGABRT with exit 134)

| Variant | Outcome | Message |
|---|---|---|
| ordinary `Ui.each` (`view`): signals, static label, callback, `Ui.when`, `Ui.component` | Compiles, spec passes | none |
| `full`: `full_template` with every requirement | Compiles, panics at runtime | `Ui.each_template: a row template may contain only static elements, text, and key placeholders` |
| `signal`: `Html.text_s` | Compiles, panics at runtime | same message |
| `when`: `Ui.when` | Compiles, panics at runtime | same message |
| `component`: `Ui.component` | Compiles, panics at runtime | same message |
| `event`: button with handler | Compiles, panics at runtime | `Ui.each_template: a row template may not contain signal-backed attributes or events` |
| `item`: `row.map(...)` | Compile error | `This map method is being called on a value whose type doesn't have that method.` … `Ui.TemplateRow` |
| `keystr`: `row.key()` | Compile error | same error, for method `key` |
| `static`: label, `key_text`, keyed `href` and `aria-label` | Compiles, spec passes | none |

All panics print `=== PANIC (no stack trace) ===`, with no site or file named. Mounting one site is enough to trigger them.

**Where each requirement stopped**
1. **Independent inputs:** failed. A row has no item, so per-row signals cannot be obtained at all (compile error). Site-level signals type-check, then panic. Only the static `Config` works, and only one value per site.
2. **Action callback:** failed, and there are two separate blocks.
   - Any event panics at runtime.
   - Even with events allowed, the builder runs once with no key, so `on_remove(key)` cannot be written. My `full` variant hardcodes `"a"` to get something to compile.
   - The nearest thing is a keyed `href`, which is a link rather than a callback.
3. **Conditional child:** failed, with a runtime panic. The only workaround I can see is two sites with precomputed partitions, which does not express a per-row condition and would change row order and identity.

**Separate from the template: a public signature cannot name a handler**
- `Node` is not in the platform's `exposes` list. Annotating `view` with `(Str -> Node.Handler)` gives `There is no module with the name Node imported into this Roc file.` (`ann/TaskRow.roc:16:38`, from `roc check`).
- So `view`, `full_template` and `event_only` are unannotated, which falls short of the brief's "public signature". The handler type is only inferred.
- This also affects ordinary `Ui.each` components.
- I also did not find a public alias for it in the docs. `Html.Attr` is nameable.

**What the template forced me to change compared with `Ui.each`**
- **Row type:** `Ui.Row(item)` is replaced by `TemplateRow`, so `row.key()`, `row.map`, `row.signal` and `row.select` are all gone.
- **String interpolation:** `"row-${key}"` becomes `row.keyed_attr(Html.test_id("row-"))`, and `Html.text(key)` becomes `row.key_text()`. Key placement is limited to prefix and suffix around one key.
- **Button label:** `"Remove ${key}"` has no route, because `button_attrs` is event-bound. I replaced it with a link.
- **Elements:** I needed the hand-written helper `Elem.Element({ namespace: Html, tag, attrs, children })` for `li` and `a`. It is copied from the fixture and exposes `Elem` shape. The brief calls `Elem.Element` allowed, but it is the one way I found to build a `li` here (`view` uses the same helper).
- **Component contract:** a row component must now be written for one mode. The same `view` cannot serve both, and its data reduces to the key.

**Awkward points**
- **Late failure:** the static-only rule is invisible in the types, because everything is `Elem`. A package consumer learns of a violation only from a runtime panic, with no location, and possibly from inside someone else's component. A nested component could fail only once it is mounted in a template. A site in a `Ui.when` would presumably fail only when that branch mounts (not tested).
- **Misleading error:** the first message, for a signal or `Ui.when`, does not name the offending construct, and the docs' suggested remedy (`Use Ui.each`) is not in the panic.
- **Item data:** the row carries `Rows(item)`, yet the item is unusable. Any row with data beyond its key is out of scope, so the real row text in the canary, a title, cannot appear. This is the largest gap.
- **Compiler friction:** an absolute platform path is rejected (`Absolute paths are not allowed for platform specifications.`), so the brief's "point at the worktree" needs a relative path. This was minor.
- **`build rc 2`:** this exit code means warnings only. The binaries were built and run.

**Opinion: a fifth concept would be needed**
- As specified, this is a static keyed list, not a component mechanism. Dynamic holes for item-derived text and attributes, plus a keyed event hole carrying the row key, are the minimum for typical rows. A conditional hole would be needed on top of that.
- Each hole has to carry row-scoped data, so I expect that to reintroduce per-row work. This is an expectation, not something measured.
- If that cost blocks holes, I would keep the API narrow and rename it to say so, for example `each_static`.
- Either way I would make template content a distinct type, such as `TemplateElem`, so these errors surface at compile time. Static text helpers would need to be available in that type. I have not tried this.
- A public `Handler` alias is needed regardless.
