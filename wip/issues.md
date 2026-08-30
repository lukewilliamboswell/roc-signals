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

## 10. Composition and reuse have no story

`Ui.component : (() -> Elem)` takes no inputs, no children, and there is no
context/provider mechanism. Reuse today means a plain Roc function returning
`Elem`, which works for leaves but gives a component no owned scope for its
inputs and no way to accept `List(Elem)` children as a slot. The maintained
apps show the cost: `main.roc` files run 500–800 lines (`split-the-bill` 820,
`status-page` 747, `support-inbox` 719) and there is no packageable UI unit an
app could import from another repo.

Design gap, not a bug: `design.md` says nothing about composition beyond the
`Ui.component` signature. Needs a decision on (a) component inputs — static
values vs `Signal(a)` vs both, (b) children as a slot, (c) whether a package can
export components without leaking `Signal.to_expr`/`from_expr` plumbing. Traces
to the author-facing product goals in `design.md`.

## 11. Coarse `Model` state defeats the scaling claim in practice

The engine is O(changed nodes), but the API steers authors toward one
`Ui.state(Model)` and `model.signal().map(...)` fan-out, so the changed set is
every derived node that reads the model. `examples/_fixtures/js-framework-benchmark/main.roc`
`render_row` derives each row's `classes` from the whole model, so selecting
one row runs 1,000 map closures and 1,000 `is_eq` calls; only propagation
*downstream* of them is pruned.

`design.md` names eager declared edges as "the tradeoff we accept" and stops.
Two candidate answers, not exclusive:

- a selector primitive (Solid's `createSelector` shape): a `Signal(key)` plus a
  per-row `Signal(Bool)` that the engine updates for exactly the two rows whose
  membership changed, O(2) closures per selection change;
- a documented state-partitioning idiom (row-local `Ui.state`, one signal per
  independent concern) with the tradeoffs stated.

Whichever lands, pin it with an `expect_metric_delta` on `derived_calls_into_roc`
in the benchmark fixture and the `large-each-*` fixtures so the property cannot
regress silently. Until then the js-framework-benchmark "select row" op is O(N)
and the design's headline claim is only true of the engine, not of apps.

## 12. Failure UX for contract violations is undefined

Duplicate keys, capability mismatches, malformed payloads, resource limits and
poisoned instances are all "host errors" in `design.md`, but nothing specifies
what the *author* sees. In the browser today a violation surfaces as whatever
`roc_ui_last_error_*` holds plus a trap; there is no construction-site
attribution, no element/scope path, and no guidance text. The native host is
better only because `lldb` is available.

Target: every contract error reaches the author as one readable message that
names the site (each site key/branch, element tag, attr or event name) and the
rule it broke, identically on both hosts, and native specs can assert on it.
Bounded diagnostic storage already exists (see "Memory management and
allocation failure"), so this is about *content* and attribution, not a new
channel. Add a fixture per error class so the message text is under test.

## 13. No JS interop door

`Sub` and app-specific interop are deferred by design, and `Html.behavior`
exists as an attach hook with no shipped semantics for passing data in or
getting events back. Any real app eventually needs a chart, map, editor or
third-party widget. Without a bounded door, authors will reach around the
runtime, which breaks the "JS is a thin executor" invariant worse than a
designed door would.

Needs a decision on the minimum viable shape: probably `behavior` as a named,
scope-owned attachment that receives a declared text/bool/record payload via
the existing boundary schema and can dispatch a custom event back through
`Html.on_custom`. Must reuse the boundary payload vocabulary and scope
lifecycle rules in `design.md`; must not add a second payload format or a
public id table. Traces to the interop product goal.

## 14. SSR / hydration / prerender — explicit non-goal, potential future

Not mentioned anywhere in `design.md`, docs, or examples. Recording it as a
deliberate non-goal so it stops being an omission: the client-side story must
be proven first (benchmark submission, Conduit in a real browser).

If it is ever picked up, the constraints already implied by the architecture:
the server would run the same engine natively and emit the command stream as
HTML; hydration must bind event ids and node ids to existing DOM without a
second reactive mechanism or a JS-side diff; `Browser.*` sources need a
server-side seeding path. The native host's simulated DOM is most of a
renderer already, which is why this is cheap to defer and plausible to add.

## 15. No payload, startup, or real-browser performance budgets

`app.wasm` is 1.18 MB (239 KB gzipped) and `www/static/signals.mjs` is 3.7k
lines (22 KB gzipped); neither is tracked, and there is no startup or
time-to-interactive measurement. All performance evidence is native-host
counters. `docs/profiling.md` maps the js-framework-benchmark submission
requirements and the browser column is entirely unfulfilled; `scripts/browser/`
drives a DOM double, not a browser.

Make these CI floors like the coverage floors: gzipped wasm and runtime size
per example, and a real-browser (Playwright) run for Conduit and the keyed
benchmark fixture. These are the Tier 3 success criteria in `design.md`; they
are the only proofs visible from outside the repo.

## 16. Workaround-site count is not zero (Product Goal 1 shortfall)

The measurable specifics behind Product Goal 1, tracked here rather than in
`design.md`: four apps encode a discriminant into an `Ui.each_str` key to get
recursion out of `Ui.when` (issue 5); ~22 `Signal.combine` sites read back by
position (issue 3); 56 hand-written `is_eq` bodies the derive could produce
(issue 2). Add a repository check that counts these so the number is visible
in CI and the zero target in Success Criteria Tier 2 is enforced, not hoped.

## 17. No newcomer timing or Conduit line-count baseline

Success Criteria Tier 2 ("Approachable") asks for a recorded time-to-deployed-
counter from a developer new to the repo, and Conduit's application line count
against the Elm and Solid RealWorld implementations. Neither has ever been
measured. Do one timed walkthrough of `getting-started.md` with a fresh person
and record the result; count non-blank, non-comment lines for the three Conduit
implementations and record the ratio, so the ~1.3× target has a baseline.

## 18. `Ui.component` has no inputs, children, or package story

`design.md` now specifies a component as an ordinary function whose arguments
are its inputs (`Signal`s, static values, `Msg`s, `List(Elem)` children) with
`Ui.component` minting the scope. Today `Ui.component : (() -> Elem) -> Elem`
is a named scope only and `Signal.to_expr`/`from_expr`/`clone_expr` are public
plumbing a package would need. Supersedes the design-side half of issue 10.

## 19. `Ui.switch` does not exist; `Ui.when` forces both branches

`design.md` specifies `Ui.when`/`Ui.switch` as retained branch builders run
only when selected, with recursive structure expressible. `platform/Ui.roc`
forces both `when` thunks at construction and there is no `switch`. Issue 5
has the ABI shape of the fix.

## 20. `Signal.select` and the selector node do not exist

`design.md` specifies a host-owned selector node kind, a complexity-budget row
(O(1) members dirtied, 0 Roc calls per key change), and a
`selector_members_dirtied` metric. None exists; selection in the keyed
benchmark fixture is O(N) map closures (issue 11).

## 21. Effects route by task-name string, not a typed registry

`http:send:` prefix routing and the task-name field are the dispatch path in
`effects_runtime.zig` and `signals.mjs`. `design.md` specifies dense
effect-registry ids built at ingestion, with the name kept for diagnostics
only.

## 22. `Sub(a)`, `Ui.subscribe`, and the widget surface are unimplemented

`design.md` specifies `Sub(a)`/`Ui.subscribe` as the inbound model that
timers and `Browser.*` sources are instances of, plus `Ui.widget`,
`Ui.widget_input_s`, `Ui.widget_event` and a mount-time widget registry.
Today the browser sources are bespoke host paths, `Html.behavior : Str -> Attr`
is an attach hook with no data channel, and no widget registry exists.
Supersedes issue 13.

## 23. Diagnostics carry no error class or construction-site path

`design.md` specifies a structured diagnostic (class enum, rule string,
scope-chain → element → edge path) printed identically by both hosts.
`roc_ui_last_error_*` holds free text with no site attribution, and the native
runner has no per-error-class fixtures. Supersedes issue 12.

## 24. Event delivery: `delegated` is on the wire but never chosen

The wire enum has `delegated`; the host always derives `native`. `design.md`
now states delegated is the effective delivery for policy-free bindings when
the host chooses it — decide whether the host ever should, or drop the enum
value.

## 25. Protocol version pinned by number in `signals.mjs`

`Protocol.version` is `11` in `www/static/signals.mjs`; the design describes
the negotiation rule without the number. Keep the number only in code and
contributing docs.

## 26. Input/form descriptors that have no engine descriptor yet

Focused masking/validation, selection-preserving normalization, file inputs,
multi-select, constraint validation, date/time controls, focus commands.
`design.md` rules that each is added as an explicit descriptor executed by both
hosts, never an executor heuristic; none is designed yet.

## 27. Storage write failures are not observable by apps

They are host diagnostics; `design.md` says an app that must know declares the
matching storage read source. Verify the read source is actually refreshed
after a failed write so that rule holds.

## 28. Extend native fault injection beyond recoverable host OOM

The native SCM fault suite currently covers recoverable host allocation failure
for selected application-shaped structural fixtures. Roc allocations are
reported and skipped because OOM cannot unwind safely across the Roc ABI.

Follow up on
[issue #20](https://github.com/lukewilliamboswell/roc-signals/issues/20) with
separately designed coverage for transient faults, Roc allocation and growth,
fatal-boundary containment, and task, timer, and resource providers. Preserve
stable allocation diagnostics and cross-platform reporting, keep the platform
CI fixture set deliberate, and do not add fault syntax to `.scm` scenarios.

## 29. Keep the focused Zig test path fast

Profile the shared-engine and native-host test binaries independently. Retain
small allocation sweeps that directly prove a private ownership, atomicity, or
allocation-free publication seam; move remaining application-shaped or
multi-stage allocation campaigns into the parallel native SCM fault suite.
Avoid removing exhaustive seam coverage merely because it uses a fault
allocator.
