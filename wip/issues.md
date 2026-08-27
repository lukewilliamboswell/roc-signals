# Outstanding issues

Work that is known, understood, and not done. Recreated at `wip/` on request;
note that `2fa88b5` deliberately removed the previous WIP notes, so keep this
file to genuinely open items and delete entries as they close.

Reproduce anything here with the nightly pinned in `.roc-version`:

```sh
export ROC_BIN=/path/to/roc_nightly-linux_x86_64-2026-08-25-cc03aa8/roc
```

---

## 1. Host regression: `5fe35ad` breaks loan-comparator

**Blocking.** `examples/loan-comparator/specs/editing-scenario-c-does-not-disturb-a-or-b.scm`
fails on the current branch, and because the spec driver stops at the first
failing example it also prevents ~159 later specs from running at all.

```
TEST FAILED at line 33:
  Expected text: "Month 1 | interest $12.00 | principal $194.56 | balance $2205.44"
  Got text:      "Month 1 | interest $12.00 | principal $2400.00 | balance $0.00"
```

Line 33 asserts on **scenario A**, inside the spec that checks *editing scenario
C does not disturb A or B*, so an edit to C bleeds into A and A's first month
clears the whole balance. That is keyed-row identity, which is what the commit
changed: `engine.zig` (+192), `host_value_registry.zig`, `identity_table.zig`,
`structural_splice.zig`.

Bisect over `04f5c02..8ef18cf` with `python3 scripts/test.py native`:

| commit | | |
| --- | --- | --- |
| `04f5c02` | tag-union batch 3 | 269 pass, 0 fail |
| `ea3ff9b` | js-framework benchmark fixture | 269 pass, 0 fail |
| `5fe35ad` | **Optimize bulk keyed structural updates** | **110 pass, 1 fail** |
| `e0cfd71` … `8ef18cf` | later commits | 110 pass, 1 fail |

Until it is fixed, gate example changes in a worktree at `ea3ff9b`, which already
contains all three refactor batches:

```sh
git worktree add --detach /tmp/gate ea3ff9b
# copy examples/ in, then run the suite there
```

## 2. Derive `is_eq` instead of hand-writing it

56 hand-written `is_eq` implementations remain across the examples and 0 use the
derive. `is_eq : _` synthesises structural equality and is verified working on
the pinned nightly for plain enums, payload-carrying tags, and nominals nested
inside nominals.

These were written by hand during the tag-union refactor before anyone checked
`docs/langref/static-dispatch.md`, so roughly 400 lines are mechanical and the
examples currently teach the verbose form. `style.md` now says to prefer the
derive, so the code contradicts the guide.

Not a blanket replacement: a few types want a genuinely custom body. Check each
before converting.

## 3. Roll out the record builder for multi-signal values

`style.md` line 88 makes `{ a: sig_a, b: sig_b }.Signal` the default, and it is
already the majority (41 record `.Signal` against 22 `Signal.combine`). The
remaining `Signal.combine` sites are read back positionally, e.g. `nth(lines, 0)`,
which is the index-alignment hazard removed elsewhere during the refactor: insert
a signal at the front and every readback shifts silently.

Deliberately excluded from the style compliance pass because it changes signal
graph shape, so the spec suite is the real check -- see issue 1.

Keep the fan-in shape in `dependency-scheduler`, where it is the teaching point,
and note that `combine` is genuinely right for a homogeneous list of the same
kind of signal.

## 4. Rename `Signal.combine`

Follows from issue 3. `combine` is correct for a dynamic, homogeneous fan-in and
wrong for a fixed set of differently-meaning signals read by index. A name like
`combine_list` or `combine_all` would carry "these are interchangeable items" and
stop it being reached for by default.

## 5. `Ui.when` is not lazy

`platform/Ui.roc` takes `(() -> Elem)` thunks and immediately forces both:

```roc
when_true: Box.box(when_true()),      # called, not stored
when_false: Box.box(when_false()),
```

So a recursive structure never terminates. Four examples work around it by
encoding a discriminant into an `Ui.each_str` row key and decoding it in the
renderer (`query-builder`, `markdown-editor`, `conduit`, `data-grid`), which is a
`to_str`/`from_str` pair per example existing only to smuggle a tag through a
`Str`.

Not a small fix: `WhenElem` crosses the ABI as two materialised `*const abi.Elem`
and `wasm_host.zig` walks both for storage discovery. The precedent is next door
-- `EachElem` carries `HostEachOps`, boxed closures the host invokes -- so
modelling `When` the same way is the shape of the fix. Touches `Elem.roc`,
`Ui.roc`, `abi_view.zig`, `wasm_host.zig`, `native_host.zig`.

A separate, smaller improvement in the same area: `each_str` hands the row
renderer a `Str` key and a *deferred* `Signal(item)`, never the item's current
value, which is the other half of why the discriminant goes through the key.

## 6. `Ui.select_of` prototype, not committed

A typed `<select>` helper. State becomes `Ui.State(t)` rather than `State(Str)`,
and the option list, the reducer and the downstream `.map(from_str)` collapse
into one declaration where wire value, label and typed value cannot drift:

```roc
Ui.select_of("Pan size", pan, [
    { wire: "recipe",  label: "Recipe's own tin", value: Recipes.Pan.OwnTin },
    { wire: "round20", label: "20 cm round",      value: Recipes.Pan.Round20 },
], input_class)
```

Implemented in `platform/Ui.roc` with a change event selecting the first option
whose `wire` matches, so an unrecognised value leaves state untouched and no
fallback has to be invented. No function parameters: two adjacent `(a -> Str)`
arguments would be the positional blindness `style.md` now warns about, and
record-held functions need `(rec.f)(x)` to call.

Prototyped against `recipe-scaler`'s pan control: type-checked, 29 tests passed.
Reverted only because it was wrongly believed to be blocked by what is now the
withdrawn `UPSTREAM_COMPILER_BUGS.md` #9. **It is not blocked.** 14 `Html.select*`
and 5 `Html.radio*` call sites would benefit.

The patch was left in a session scratch directory and is likely gone; the design
above is enough to redo it.

## 7. `Ui.tagged_text` not prototyped

58 sibling `*_text` / `*_class` function pairs across 19 examples derive a caption
and a CSS tone from the same tag. They must agree, and nothing enforces it -- the
cheap way to "guarantee" agreement is to derive one from the other, which was the
bug removed from `recipe-scaler`, `token-editor`, `loan-comparator` and
`status-page`.

`kanban-board` shows the good shape: one `WipState` feeding caption, `data-wip`
attribute and tone from a single `map2`. Whether that deserves API or is only an
idiom is unresolved. `select_of` looked obviously right in the abstract and only
became useful once written, so the honest test is three or four real call sites,
not the signature.

## 8. Compiler bugs not filed upstream

`UPSTREAM_COMPILER_BUGS.md` #5, #6, #7 and #8 have reproductions but no issue.
#6 and #8 have the cheapest write-ups: #6 ships `repro/var-bool-inference/`, and
#8 is a one-paragraph description of `List.sort_with`'s first-element pivot.

#5 and #7 share the "two identical printed types" signature and may share a root
cause in method-constraint solving; worth mentioning that in whichever is filed
first.

## 9. The spec driver stops at the first failing example

`scripts/test.py native` aborts the whole run when one example fails, so a single
failure hides every later example. Issue 1 currently costs ~159 unrun specs this
way, and the js-framework benchmark's timeouts did the same earlier, hiding five
`_fixtures` specs.

Continuing and reporting all failures at the end would make a red run diagnosable
in one pass. `--fail-fast` already exists, so the current behaviour could become
opt-in.
