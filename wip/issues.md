# Outstanding issues

Implementation and evidence work toward [the target architecture](../design.md).
Remove entries as they close. Use the toolchain pinned in `.roc-version` and
the commands in [contributing](../www/content/docs/contributing.md).
GitHub issue and PR numbers refer only to the linked external discussions.

These entries describe target work, not shipped features. Older counts and
implementation observations are investigation snapshots; recheck them before
planning a patch.

## Priority and critical path

The hypothesis is that pure Roc, explicit dependencies, and scoped ownership can
deliver competitive browser UI performance through an API authors can compose
naturally. The largest measured gap is bulk construction. The next experiment
must test whether sharing explicit row declarations reduces that cost without
weakening semantics or requiring an awkward second programming model.

- **P0 — Validate now.** Run the smallest experiment that can reject the
  performance-and-composition hypothesis. The first-gate paragraphs bound this
  cycle; they do not require completing every broader audit or budget program.
- **P1 — Make the result usable.** Resolve high-impact application semantics and
  browser interaction gaps once the core approach has evidence.
- **P2 — Broaden and harden.** Expand integration, coverage, and workflow quality
  when the validated core or a concrete application needs them.
- **P3 — Defer.** Convenience, naming, and housekeeping with limited impact on
  the current hypothesis.

The critical path is: reproducible production baseline → focused work/ownership
checks and one component canary → smallest row-template experiment → repeatable
performance result and an author exercise → broaden or revise the approach.
Capture the existing component workflow before the experiment so ergonomics has
a comparison too. Within each priority, entries follow the intended work order.

Do not wait for the new action API, a complete widget framework, or the full
accessibility program to measure the first construction slice. Preserve their
existing behavior and run the interaction checks affected by the slice.
Ownership, lifetime, equality, and publication checks on changed paths are
acceptance requirements at every priority, not deferred hardening.

If optimized gains do not exceed observed timing spread, costs merely move to
decoding or peak memory, or the component requires encoding tricks, stop broad
rollout and revise the hypothesis. Promote lower-priority work when evidence
shows it blocks the experiment; a confirmed safety defect blocks affected
shipping work regardless of its list position.

---

## Establish production cost budgets and repeatable acceptance evidence

**Priority: P0** — Establish the comparison needed to accept or reject the
construction hypothesis.

First gate: reproduce create-1k/create-10k plus update, select, and swap on one
production configuration, and record allocation/byte counts and timing spread.
Start with this small baseline; the complete release-budget program can follow.

[PR #38](https://github.com/lukewilliamboswell/roc-signals/pull/38) provides real
browser evidence: partial update was approximately tied with Solid, while
create-10k remained about 5.6× slower. These are reported checkpoint results,
not measurements of the current checkout. Remove-one was excluded because the
driver did not exercise the targets symmetrically; do not treat the published
table as complete nine-operation evidence.

The next work is a reproducible acceptance policy, not another claim that all
performance evidence is native. Follow [profiling](../docs/profiling.md):

- Record toolchain, artifact identity, browser, machine, samples, spread, and
  all required operations; repair or explicitly account for missing cases.
- Measure creation/retirement per row, element, binding, and scope, alongside
  sparse updates. Separate Roc construction, ingestion, command decode/apply,
  and browser layout/paint.
- Measure startup, compressed size, slower representative environments,
  steady-state live bytes, retained capacity, and peak transaction bytes.
- Gate deterministic work and size ceilings in CI. Keep ordinary shared-runner
  timing diagnostic; define repeated-measurement budgets and noise tolerance
  for production release acceptance.
- Establish one numeric target policy. Earlier design text used both 1.5×
  vanilla and 2× Solid (1.25× stretch); these were distinct aspirations, not
  interchangeable gates. Choose and justify targets alongside the evidence.

Done when checked-in measurement contracts and release evidence cover all cost
dimensions without treating a low patch count or a fast isolated sample as proof
of end-to-end performance. Template construction work is tracked under [row templates](#gate-row-templates-on-composition-as-well-as-construction-cost).

## Audit foundation work assertions after Rows migration

**Priority: P0** — Ensure a speedup preserves locality instead of hiding work
elsewhere.

First gate: audit or add only the scaling assertions exercised by the template
experiment, at two sizes. Expand coverage after the experiment earns further
investment.

The former counts in this entry predated the Rows work and are not a current
coverage inventory. Audit the large keyed fixtures and benchmark manifests
against the revised cost model.

Counters must expose candidate evaluations, pruned work, scanned descriptors,
graph maintenance, item/equality work, key bytes, order maintenance, allocations,
and command bytes. A closure count does not bound the work inside the closure.

Add focused scaling assertions at multiple sizes for update, append, removal,
snapshot/stale sibling, and reorder. Preserve exact row/structural invariants;
bound incidental engine work. Deliberately introduce a whole-site scan or broken
oracle in an isolated test experiment and confirm the relevant guard fails.
Revert that mutation before landing. Report remaining uninstrumented costs
rather than treating absent counters as zero work.

## Verify production capability and lifetime validation

**Priority: P0** — Make the optimized ownership boundary trustworthy before
accepting its speed.

First gate: trace production validation and rejection behavior on the values and
callbacks the experiment touches. Any unsafe path there blocks acceptance; the
full audit need not precede an isolated prototype.

The target now explicitly requires capability, active-frame, and handle-lifetime
validation before typed access in production. Earlier design text incorrectly
described required wiring checks as debug-only.

Trace every erased read/clone/compare/drop and extension callback. Identify
checks that prevent incompatible typed access separately from redundant debug
audits. Release-build tests must reject mismatched capabilities, inactive frames,
and stale handles before entering incompatible typed code. Verify ownership on
both rejection and teardown, plus optimized native and Wasm behavior.

Do not infer that a passing safe-build suite makes unchecked release routing
structurally safe. Performance work may optimize validation but may not remove
the required boundary contract.

## Validate component composition and placement ownership

**Priority: P0** — Test whether shared construction can support ordinary
reusable components.

First gate: use one packaged row component with independent inputs, an action
callback, and a conditional child as the template composition canary. Audit
wider placement cases as follow-up.

An ordinary Roc function can already accept static values, signals, callbacks,
and children. The zero-argument `Ui.component` wrapper is not evidence that
components cannot accept inputs. The target now distinguishes descriptor
construction, source ownership, and the lifetime of mounted child declarations.

Audit ingestion against that contract and add a packaged component fixture:

- Pass a named record of independent signals without introducing whole-record
  invalidation; compare work before and after component extraction.
- Pass caller-owned state into a conditional child. Closing the child disposes
  declarations mounted inside it while retaining the caller's source.
- Reopen the child and prove fresh local state plus the retained external draft.
- Exercise two component instances and repeated placement of child descriptions;
  source aliasing and per-placement structural identity must not be conflated.
- Export through public types without descriptor plumbing or host ids.

Resolve any representation needed to preserve this distinction in one shared
engine. Align public examples only when they match shipped behavior.

## Gate row templates on composition as well as construction cost

**Priority: P0** — Attack the largest measured gap with the smallest falsifiable
experiment.

First gate: implement one explicit static row-template shape and compare
optimized construction time and allocation traffic with the ordinary builder.
Preserve update/select/swap behavior and scoped ownership. Broaden template
expressiveness only after this slice produces a repeatable improvement.

Continue [GitHub issue #39](https://github.com/lukewilliamboswell/roc-signals/issues/39)
using PR #38's measured construction gap. Its symbolic-template direction must
retain the existing graph, scope, capability, identity, and transaction laws;
arbitrary `Row -> Elem` builders cannot be cached by observing returned content.

Before fixing public names, exercise a packaged row component, typed row action,
independent projections, selection, and conditional/delayed structure. Show the
public path for composing a dynamic fragment inside a template and account for
its cost. No host ids or implicit ownership knowledge should reach the app.

Retain the linked issue's staged ownership/fault/plateau gates and construction
allocation target. Add author exercises, migration examples, code-size/peak-memory
measurement, and preservation of focused editing interaction. A benchmark-only
template vocabulary does not satisfy the architecture.

## Measure author effort with realistic changes

**Priority: P0** — Check that the performance path remains usable before
committing to its API.

First gate: have a developer unfamiliar with the implementation extract and
modify the same row component using the proposed public surface. Record extra
concepts and workarounds; run the broader newcomer program after this canary.

Run recorded newcomer exercises for deploying a counter, extracting a component,
adding validation, preserving an edit across navigation, and diagnosing excess
work. Capture completion time, errors, documentation detours, and required
framework-specific ceremony. Include independently changing component inputs and
repeated submission so the exercises evaluate the revised target contracts.

Line counts against comparable RealWorld implementations remain supporting
evidence; they are not the ergonomic acceptance gate. Record what code is counted
and compiler limitations separately. Done when someone outside the implementation
effort can complete the exercises from the maintained documentation.

## Express action occurrences without serial-number encodings

**Priority: P1** — Remove repeated-action encoding tricks from common forms and
row actions.

The target distinguishes current values from accepted occurrences. Equality may
prune values but must not erase two identical submissions, retries, or refreshes.
Maintained forms currently demonstrate serial counters or request-string suffixes
to distinguish repeated intent.

Design typed pure action handlers that describe state transitions and effect
requests through the shared engine. Choose API names only after rewriting a
form submit, retry button, and row action. Do not add a second reactive runtime.

Acceptance: two equal-payload actions produce two accepted occurrences; no action
fires solely because its descriptor mounted; ownership, request superseding,
refusal, and cancellation remain explicit. Include native semantics, production
browser integration, and documentation migration.

## Coordinate independent sources in one action

**Priority: P1** — Make fine-grained state practical for coherent domain
transitions.

`State.on_unit_with` snapshots one additional source while writing one
destination; it is not a general multi-source transaction API. Design the
declaration/ABI for one coherent read snapshot and a prepared write set with
at most one replacement per destination.

Acceptance: reset a partitioned form and change dependent account settings with
one propagation. Observers see only settled values; duplicate destinations fail
before commit; disposal and allocation failure publish no prefix. Preserve
fine-grained subscriptions outside the affected write set. Define stable action
ordering and how action-produced effects refer to computed next values.

## Pin lifecycle behavior across removal, hiding, and placement

**Priority: P1** — Protect drafts and local state as applications change
structure.

Use the observable lifetime table in `design.md` as the target. Audit both
engine behavior and maintained claims that state survives filtering.

Cover same-site reorder, removal of another row, filtered-out removal and later
reinsertion, remove/reinsert within one unpublished edit batch, key change,
cross-site movement, branch switching, and root/component disposal. Prove
state, effects, cancellation, and rendered structure together.

Add examples that lift drafts to a longer-lived owner for filtering, pagination,
virtualization, and navigation. Attribute hiding retains live scope/effects;
it is not suspension. Do not introduce `keep_alive` until its activity,
bounded-memory, focus, and resumption semantics have a separate reviewed design.
Component child placement is also covered under
[component composition and placement ownership](#validate-component-composition-and-placement-ownership).

## Document and test equality as an observation contract

**Priority: P1** — Ensure pruning preserves meaning and effect behavior.

Audit custom `is_eq` implementations for fields read by downstream closures,
sinks, and effects. Document conservative inequality versus incorrectly treating
observable changes as equal. Preserve generation equality for `Rows` and
explicit content equality; neither substitutes for occurrence identity.

Cover expensive equality, independently built equal-content Rows, normalized
no-op edits, and supported non-reflexive comparisons. Ensure the scheduler does
not depend on unstated equality laws. Record comparison/allocation costs in
performance evidence. Keep [derive adoption](#derive-is_eq-instead-of-hand-writing-it) separate from semantic audits.

## Implement turn ordering and external-failure containment

**Priority: P1** — Bound feedback and contain failures across the shared action
and browser path.

Audit host transactions against the target action/turn rules:

- Coherent source write sets settle before value-change observers.
- Effect-produced state changes start subsequent ordered turns.
- Synchronous widget callbacks during a drain enter bounded deferred ingress,
  never re-enter an incomplete engine turn or command batch.
- Queue acceptance reserves capacity. Only explicitly latest-value sources may
  coalesce; distinct accepted actions remain ordered.
- Effect feedback has a configured consecutive-turn bound and useful diagnostics.
- Cancellation invalidates queued/late settlements without resurrecting a scope.

Fault-test a later engine step failing after an earlier step sealed commands.
Without whole-call rollback, that outcome is fatal containment, not recoverable
pre-call state. Distinguish atomic command publication from external execution:
a widget or browser operation may fail after earlier effects ran. Specify typed
operation failures, unexpected-executor containment, cleanup, and no automatic
batch retry. Cross event sequences and fault positions with a model/fuzz oracle.

## Design input and accessibility descriptors

**Priority: P1** — Make editing and focus behavior usable in real applications.

Make focus ownership/restoration, selection, composition, accessible names and
relationships, and focused keyed-row movement explicit contracts. Define scoped
target references without exposing engine ids. A removed target cannot receive
a deferred write or focus command.

The existing guarded `SetValue` rule defers unequal values while focused or
composing. Validate reset, server correction, rejected edits, masking, blur,
and composition-end sequences before extending it. Do not infer browser
correctness from the native model.

Design focused masking, normalization, file inputs, multi-select, constraint
validation, and date/time controls only with clear producer/consumer semantics.
Pin native command behavior and browser interaction tests together; broader
accessibility and end-to-end evidence is tracked under
[browser interaction evidence](#establish-browser-interaction-and-accessibility-evidence).

## Establish browser interaction and accessibility evidence

**Priority: P1** — Validate the production user journey beyond the simulated
DOM.

Keep exhaustive shared semantics native and focused JS/Wasm contract coverage.
Add a small production-browser journey suite for submit/retry, navigation,
focused row movement, keyboard access, child mounting, and widget lifecycle.

Cover focus restoration and first-error focus, selection/composition, accessible
relationships, and cancellation/disposal while editing. State supported browser
environments and record what automation cannot establish; include manual
assistive-technology evaluation where necessary. A native role locator passing
does not prove the browser's accessible tree or keyboard usability.

Do not duplicate every engine spec. The additional layer proves integration,
including that the compiled app, host, executor, and actual browser agree.

## Complete diagnostics and author-visible attribution

**Priority: P1** — Make semantic and performance failures diagnosable by
application authors.

The target already defines a structured diagnostic: error class, broken rule,
and bounded scope/element/edge path. Audit the current free-text error paths
against that contract and add one fixture per error class on both hosts.

Include capability mismatch, stale lifetime, malformed payload, resource limit,
feedback-turn exhaustion, and executor containment. Establish how unnamed
component functions receive useful attribution without requiring unavailable
compiler source-location features. Reserve formatting storage before failure.

For unexpected recomputation, provide a bounded, on-demand explanation of the
invalidating dependency and owning scope without scanning the graph on normal
updates or exposing opaque values. This diagnostic work is distinct from
[production safety checks](#verify-production-capability-and-lifetime-validation).

## Align public guidance and maintain separate contract authorities

**Priority: P1** — Keep adoption guidance aligned with the contracts each
validated change ships.

The design now separates semantic laws from its target API, protocol, and
representative-app appendices. Audit public docs against shipped behavior before
updating them; do not publish target APIs as already available.

Resolve conflicting guidance about `Signal(Props)` versus records of independent
signals, serial-number request encodings, filtered-row persistence, caller
sources versus child placement, state command availability, and native/browser
test scope. Review overbroad claims that text-only content removes every
injection risk; arbitrary attributes, URLs, and registered widgets still need
explicit trust and content policies.

For API changes, provide migration guidance separately from wire compatibility.
Protocol evolution must validate mixed/stale artifacts before mount. Extract
appendices into dedicated normative specifications only when their authoritative
locations and links are agreed; do not copy partial target contracts into
shipped-reference pages. Update [performance evidence targets](#establish-production-cost-budgets-and-repeatable-acceptance-evidence) and
[author exercises](#measure-author-effort-with-realistic-changes) as those changes land.

## Effects route by task-name string, not a typed registry

**Priority: P2** — Establish typed routing needed by the broader
external-integration model.

`http:send:` prefix routing and the task-name field are the dispatch path in
`effects_runtime.zig` and `signals.mjs`. `design.md` specifies dense
effect-registry ids built at ingestion, with the name kept for diagnostics
only.

## Complete the declared subscription and widget boundary

**Priority: P2** — Validate the one-door model with a real widget after the core
path is proven.

The target specifies `Sub(a)`/`Ui.subscribe`, scope-owned browser sources,
`Ui.widget`, typed input/events, and a mount-time widget registry. Audit the
shipped surface against that target; earlier observations found bespoke browser
source paths and an attachment hook without a complete data channel.

Use a real chart or editor as the canary. Prove typed inputs, repeated events,
attach/update/detach, cancellation, bounded registrations and payloads, and
unknown-widget diagnostics. Synchronous callbacks during command execution must
follow [the deferred ingress contract](#implement-turn-ordering-and-external-failure-containment). A throwing widget must follow the
external-failure contract, with no batch retry or claimed rollback of effects.

Keep the one declared boundary vocabulary, scope ownership, and engine scheduling
authority.

## Storage write failures are not observable by apps

**Priority: P2** — Close persistence failure visibility for applications that
depend on storage.

They are host diagnostics; `design.md` says an app that must know declares the
matching storage read source. Verify the read source is actually refreshed
after a failed write so that rule holds.

## Extend native fault injection beyond recoverable host OOM

**Priority: P2** — Expand fault coverage beyond the focused ownership and
transaction gates.

The native SCM fault suite currently covers recoverable host allocation failure
for selected application-shaped structural fixtures. Roc allocations are
reported and skipped because OOM cannot unwind safely across the Roc ABI.

Follow up on
[issue #20](https://github.com/lukewilliamboswell/roc-signals/issues/20) with
separately designed coverage for transient faults, Roc allocation and growth,
fatal-boundary containment, and task, timer, and resource providers. Preserve
stable allocation diagnostics and cross-platform reporting, keep the platform
CI fixture set deliberate, and do not add fault syntax to `.scm` scenarios.

## Keep the focused Zig test path fast

**Priority: P2** — Reduce iteration cost if test runtime becomes a measured
bottleneck.

Profile the shared-engine and native-host test binaries independently. Retain
small allocation sweeps that directly prove a private ownership, atomicity, or
allocation-free publication seam; move remaining application-shaped or
multi-stage allocation campaigns into the parallel native SCM fault suite.
Avoid removing exhaustive seam coverage merely because it uses a fault
allocator.

## Roll out the record builder for multi-signal values

**Priority: P2** — Remove positional composition hazards in the maintained
examples.

`style.md` line 88 makes `{ a: sig_a, b: sig_b }.Signal` the default, and it is
already the majority (41 record `.Signal` against 22 `Signal.combine`). The
remaining `Signal.combine` sites are read back positionally, e.g. `nth(lines, 0)`,
which is the index-alignment hazard removed elsewhere during the refactor: insert
a signal at the front and every readback shifts silently.

Deliberately excluded from the style compliance pass because it changes signal
graph shape, so the native semantic specs and work budgets are the acceptance check.

Keep the fan-in shape in `dependency-scheduler`, where it is the teaching point,
and note that `combine` is genuinely right for a homogeneous list of the same
kind of signal.

## Derive `is_eq` instead of hand-writing it

**Priority: P2** — Reduce equality boilerplate after checking each type's
semantic contract.

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

## Workaround-site count is not zero (Product Goal 1 shortfall)

**Priority: P2** — Keep proven ergonomic improvements from regressing.

The measurable specifics behind Product Goal 1, tracked here rather than in
`design.md`: historical counts included roughly 22 positional `Signal.combine`
readbacks and 56 hand-written `is_eq` bodies. Recount while doing
[record-builder adoption](#roll-out-the-record-builder-for-multi-signal-values) and
[equality derive adoption](#derive-is_eq-instead-of-hand-writing-it). Add a repository check that counts these so the number is visible
in CI and the zero target in Success Criteria Tier 2 is enforced, not hoped.

## Compiler bugs not filed upstream

**Priority: P2** — Resolve upstream limitations when they obstruct a
representative workflow.

`UPSTREAM_COMPILER_BUGS.md` #5, #6, #7 and #8 have reproductions but no issue.
#6 and #8 have the cheapest write-ups: #6 ships `repro/var-bool-inference/`, and
#8 is a one-paragraph description of `List.sort_with`'s first-element pivot.

#5 and #7 share the "two identical printed types" signature and may share a root
cause in method-constraint solving; worth mentioning that in whichever is filed
first.

## The spec driver stops at the first failing example

**Priority: P2** — Verify and improve failure reporting if the historical runner
issue remains.

`scripts/test.py native` aborts the whole run when one example fails, so a single
failure hides every later example. An earlier equality-related failure was reported to hide roughly 159 specs
this way, and the js-framework benchmark's timeouts did the same earlier, hiding five
`_fixtures` specs.

Continuing and reporting all failures at the end would make a red run diagnosable
in one pass. `--fail-fast` already exists, so the current behaviour could become
opt-in.

## `Ui.select_of` prototype, not committed

**Priority: P3** — Add focused form convenience after the core action and state
model settles.

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

## `Ui.tagged_text` not prototyped

**Priority: P3** — Validate a presentation helper only after repeated real call
sites justify it.

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

## Rename `Signal.combine`

**Priority: P3** — Defer naming churn until composition evidence demonstrates a
benefit.

Follows from [record-builder adoption](#roll-out-the-record-builder-for-multi-signal-values). `combine` is correct for a dynamic, homogeneous fan-in and
wrong for a fixed set of differently-meaning signals read by index. A name like
`combine_list` or `combine_all` would carry "these are interchangeable items" and
stop it being reached for by default.

## Event delivery: `delegated` is on the wire but never chosen

**Priority: P3** — Change listener delivery only when profiling identifies
material cost.

The wire enum has `delegated`; the host always derives `native`. `design.md`
now states delegated is the effective delivery for policy-free bindings when
the host chooses it — decide whether the host ever should, or drop the enum
value.

## Protocol version pinned by number in `signals.mjs`

**Priority: P3** — Audit version-source housekeeping alongside an actual
protocol change.

`Protocol.version` is `11` in `www/static/signals.mjs`; the design describes
the negotiation rule without the number. Keep the number only in code and
contributing docs.
