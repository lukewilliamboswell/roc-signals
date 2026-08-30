# Outstanding issues

Work that is known, understood, and not done. Recreated at `wip/` on request;
note that `2fa88b5` deliberately removed the previous WIP notes, so keep this
file to genuinely open items and delete entries as they close.

Reproduce anything here with the nightly pinned in `.roc-version`:

```sh
export ROC_BIN=/path/to/roc_nightly-linux_x86_64-2026-08-25-cc03aa8/roc
```

---

## 1. Derive `is_eq` instead of hand-writing it

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

## 2. Roll out the record builder for multi-signal values

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

## 3. Rename `Signal.combine`

Follows from issue 2. `combine` is correct for a dynamic, homogeneous fan-in and
wrong for a fixed set of differently-meaning signals read by index. A name like
`combine_list` or `combine_all` would carry "these are interchangeable items" and
stop it being reached for by default.

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
`design.md`: ~22 `Signal.combine` sites read back by position (issue 3); 56
hand-written `is_eq` bodies the derive could produce
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

## 30. The Wasm host cannot run the 10,000-row benchmark

The production host exhausts Wasm linear memory while preparing the atomic
state transaction for `create_10k`. Because `update_10k`, `append_1k_to_10k`,
and `clear_10k` all use the same 10,000-row setup, four of the nine required
browser benchmark operations currently cannot produce a sample. This is a
product failure reported by the ordinary production artifact, not overhead in
the diagnostic companion.

The smaller case shows why. After `create_1k`, the production instance has
grown from 148 to 5,465 64-KiB pages: 358,154,240 bytes committed, including
348,454,912 bytes of growth for one event. The paired diagnostics report only
1,913,986 live Roc bytes and 19,828,431 live host bytes at the end, but a
185,936,806-byte host peak. The command buffers account for 1,897,259 bytes of
growth, so neither durable live data nor the wire batch explains the committed
capacity.

Repeated same-size replacement is not an unbounded retained leak in a short
run, but it makes the capacity problem worse: host live storage rises to
36,150,855 bytes by the third replacement and plateaus, while committed memory
reaches 6,589 pages (431,816,704 bytes) by the fifth. This points to oversized
transaction scratch, allocator fragmentation/high-water retention, or both.
The next investigation needs allocation size/source buckets for host
allocations during preflight and commit; aggregate bytes alone cannot identify
which reservation owns the peak.

Reproduce on the Wasm benchmark branch after merging `origin/main` at
`ee5fa60`:

```sh
python3 scripts/test.py wasm-bench \
  --roc-bin /path/to/roc \
  --bench-case create_10k \
  --bench-warmups 0 \
  --bench-iterations 1 \
  --bench-samples 1
```

Done means all four 10,000-row workflows complete in the production host,
fresh-instance committed pages scale plausibly from 1,000 to 10,000 rows, and
an exact work/allocation regression test bounds the reservation responsible for
the current peak. Do not fix this by increasing the Wasm maximum or weakening
atomic preflight.

## 31. Roc allocation validation is linear in all live allocations

Every valid `roc_dealloc` and `roc_realloc` searches the
`roc_allocations` array by pointer. `findExactRocAllocationIndex` and the
interior-pointer fallback in `src/wasm_host.zig` are linear scans, so ordinary
allocation traffic costs O(live Roc allocations) per operation. After creating
1,000 rows the ledger contains 43,087 live allocations. That turns unrelated
small changed-set updates into hundreds of millions of pointer comparisons.

One-sample triage numbers on an Apple M2 with the production ReleaseFast host,
Roc `--opt=size`, Node 23.9.0, and `origin/main` at `ee5fa60` make the pattern
visible:

| Operation | Production event | Roc allocs | Roc deallocs | Render commands |
| --- | ---: | ---: | ---: | ---: |
| select one row | 4.4 ms | 111 | 111 | 2 |
| swap two rows | 322 ms | 14,053 | 14,053 | 2 |
| remove one row | 345 ms | 15,037 | 15,080 | 3 |
| create 1,000 | 1.20 s | 91,041 | 48,039 | 34,000 |
| replace 1,000 | 3.54 s | 91,054 | 91,054 | 35,000 |

These durations are hotspot triage, not a stable performance baseline; the
exact allocation and command counts are the stronger evidence. For example,
swap spends 321.7 ms inside `roc_ui_event` while JavaScript executes only two
move commands in 0.23 ms. Its deterministic engine work is 1,000 key hashes,
2,000 key comparisons, 1,000 item comparisons, and 1,000 reused rows, but each
of its 14,053 deallocations also scans a ledger that starts near 43,000 entries.

Use an O(1) exact-pointer index for the valid hot path and update it atomically
with the allocation ledger. Interior-pointer and nearest-allocation scans may
remain cold diagnostic paths after an exact lookup fails. Preserve the current
alignment checks, already-freed diagnostics, failure atomicity, and swap-remove
bookkeeping. Pin the result with a Wasm-host work counter or a scaling test that
proves successful deallocation/reallocation does not inspect the live ledger;
wall-clock thresholds alone are not sufficient.
