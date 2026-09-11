# Settling the effect model

## Goal

The `defaulted-gui-style` branch made two deliberate architectural changes to
the native platform: presentation moved to defaulted props records, and the
task transport was replaced by Roc effectful closures scheduled by the engine
and run on worker threads. The code now embodies semantic laws that
[design.md](../design.md) does not state — and in several places states the
opposite of. This document names the laws the branch chose, the decisions it
left open, and the objectives that remain before the platform can claim one
coherent effect architecture again.

This is a plan, not a new public contract. `design.md` remains the
architectural authority, and the first objective below is to make that true
again: today the authority and the implementation disagree about behavior the
branch changed on purpose, which [AGENTS.md](../AGENTS.md) treats as the one
legitimate reason to rewrite the design. High-level objectives only; public
spellings, encodings, and delivery steps belong in issues and the protocol
documents.

## Where the branch landed

Facts, so the objectives have a shared baseline. Evidence lives in the branch
history and the files cited.

**Actions are data the engine interprets.** An event handler returns an
`Action(a)`: `Action.update(changes)` is one atomic batch of state changes;
`Action.then(changes, effect!)` is a batch followed by an effectful Roc
closure whose result is the next action
([platform-gui/Action.roc](../platform-gui/Action.roc)). Every state change is
a reducer applied at its own commit against the value the state holds then —
`State.set` is the explicit replacement form — so a chain that waited on an
effect never writes a value captured before the effect ran. Duplicate targets
in one batch are rejected. This is a substantial down payment on the action
laws `design.md` already states in *Values, Actions, and Coordinated State*.
Note that the coordinated batch itself is *shared*, not native-only:
[platform-shared/Ui.roc](../platform-shared/Ui.roc) already lowers
`set_cmd` and `update_states` to the same `UpdateChanges` command both hosts
execute. What is native-only is the `Action` module and the `Then` command.

**External services are hosted effectful functions.** `Env.var!`, twelve
`Files` primitives, and `Http.send!` are `!` functions callable only inside an
effect ([platform-gui/main.roc](../platform-gui/main.roc)). Everything above
the primitives — text encoding, previews, scan budgets, atomic write via
temp-and-rename, asset verification, log following — is ordinary Roc in
[platform-gui/Files.roc](../platform-gui/Files.roc) and example code. The
bounded task queue, the `files1` codec, and the task transport are deleted,
and no native service or example routes through the task API any more. The
shared `Signal` task surface (`Task`, `from_task`, `cancel`) is however still
compiled into and exposed by the native platform via the generated module
copies — an orphan objective 1 must decide about, since what a native caller
gets today is discoverable only by experiment.

**Every effect runs on its own worker thread.** The engine queues prepared
effects after the turn settles; the Rust host runs each on a dedicated thread
and posts the result back to the UI thread
([crates/gpui-host/src/workers.rs](../crates/gpui-host/src/workers.rs)).
Choosers block their worker while the UI thread shows the dialog. Results
apply in completion order
([native-gui.md](../www/content/docs/native-gui.md)).

**Effect lifetime is independent of scope lifetime.** Disposing the scope
that started an effect no longer cancels it: the effect reparents to the
nearest surviving ancestor scope, and a result that arrives after its scope
is gone applies to the states that still exist
([src/signals/engine.zig](../src/signals/engine.zig)). The sharp edge: a
handler-time batch is all-or-nothing, but an *effect-result* batch applies
per-write — writes to surviving states land while writes to retired states
are skipped, with no counter and no diagnostic. There is no cancellation
surface, no supersession primitive, no bound on concurrent effects, and no
bound on effect-triggered turns.

**The web platform did not move.** `platform-web` still exposes the
task-transport model — `Signal.Task`, `from_task`, `cancel`, its own
`Http` module, string-routed effects — and the browser host treats a `Then`
command as an unreachable contract violation (a bare panic). The two
platforms currently embody two different effect architectures, and the docs
state the split flatly: "The browser platform does not run `then` effects"
([native-gui.md](../www/content/docs/native-gui.md)).

**The prose is behind the code, including inside this branch.** The one
paragraph the branch added to `design.md` (the `Then` command) says effects
run on the UI thread and that disposed-scope effects are released — both
superseded by later commits on the same branch. The `Action.then` doc comment
contradicts its own inline comments the same way
([platform-gui/Action.roc](../platform-gui/Action.roc)), and a host doc
comment still claims `Then` effects run on the UI thread
([src/native_host.zig](../src/native_host.zig)). `design.md`'s
observable-lifetime table still says removing a key will "cancel its active
work"; its *Requests and cancellation* section still describes
disposal-driven cancellation; its Product Goal 5 still routes native services
through "explicit native task kinds"; Appendix A still catalogs the task API;
the presentation section still says a supplied style record "replaces its
helper defaults".

## The principles to ratify

These are the laws the branch's end state implies. Ratifying them — or
consciously rejecting one — is the substance of the design overhaul. Stated
as principles, not mechanisms:

1. **Description is pure; behavior is data; effects are host-scheduled
   continuations.** The app builds UI and reduces state in pure code. The
   only place effectful Roc exists is inside an effect the engine runs after
   a commit, and the only externally visible operations inside it are the
   platform's hosted primitives. This restates the thesis honestly: "pure
   Roc" no longer means "no effectful Roc anywhere"; it means effects are
   declared in actions, sequenced by the engine, and can neither observe nor
   mutate mid-turn state.

2. **No stale writes, by construction.** State changes are reducers at their
   own commit; effect chains re-snapshot their declared reads. The platform
   never applies a value captured before an intervening commit. This is the
   law that makes everything else safe, and it deserves to be stated as the
   replacement for the old cancellation-based safety story.

3. **Scope disposal governs structure and subscriptions, not in-flight
   work.** A scope owns what it declared: rendered structure, state,
   subscriptions, timers. An effect belongs to the *intent* that started it
   and outlives the scope, reparenting to the nearest live ancestor. The
   part of this law the branch left implicit must be decided, not assumed:
   as shipped, an effect result's batch applies per-write against whichever
   states survive. The precedent is the existing stale-settlement law — a
   late result for a retired owner is released, not applied — but partial
   application *within one batch* is new, and it currently happens silently.
   Ratification chose: `design.md`'s *Requests, effects, and cancellation*
   now records observable per-write application for effect results — the
   counter and diagnostic naming the skipped destination are the follow-up
   that makes the skip visible — while handler-time batches remain
   all-or-nothing.

4. **Races are application state.** The platform guarantees each result
   applies atomically per the law above, in completion order, against
   settled current values. Which result wins is domain logic the app
   expresses in its reads — a request counter, a phase. If experience shows
   every real app hand-rolls the same counter, that is Product Goal 1
   pressure for a platform supersession primitive; until then the pattern is
   the documented answer, and the design should say so rather than imply the
   old superseding task kinds still exist.

5. **Bounded resources remain the goal.** The 16-operation bound died with
   the transport, and nothing replaced it: today an unbounded number of
   worker threads, queued results, reparented effects, and consecutive
   effect-triggered turns can exist. "Cost is visible and bounded" is a
   product goal, so the model owes explicit bounds and refusal semantics
   of its own — for admitted effects, queued results, feedback turns, and
   shutdown — as follow-up refinements, per the owner's direction, rather
   than gates on the shipped model.

6. **One mechanism per platform.** Whatever the cross-platform outcome,
   a single platform must never carry two effect mechanisms for one job, and
   any divergence between platforms must be a declared capability difference
   — as `Gui` vs `Html` already is — not an accident of migration order.
   Whether one *model* spans both platforms is deliberately not part of this
   principle; that is objective 2's decision to make.

## Objectives

### 1. Overhaul `design.md` to ratify the native effect laws

Rewrite the effect-related sections as a deliberate architecture change,
scoped to what the branch actually decided — the native laws — while
*annotating* the web-model sections (tasks, `Cmd`/`Sub`, the effect
registry) as platform-scoped pending objective 2, rather than deciding their
fate here. Concretely: the thesis paragraph's purity claim; Product Goal 5's
"one door" wording; *Values, Actions, and Coordinated State* (much of it is
now shipped on native — say so); the `Then` paragraph; *Native tasks,
timers, and external state*; the observable-lifetime table's removal row
("cancel its active work") and the *Requests and cancellation* section;
the window-close contract, whose "async work completes through ordinary task
settlement before the app may permit closure" is incoherent now that task
settlement is gone and effects outlive scopes; *Turns, effects, and
reentrancy* (effect-produced turns, completion-order application, and the
feedback bound need restating against worker-thread reality); Appendix A's
task surface; and the presentation section's "a supplied record replaces its
helper defaults" sentence, which the props rework made false. The sweep
includes stale *code* comments, which [AGENTS.md](../AGENTS.md) holds to the
same standard — the `Action.then` doc comment and the native host's
UI-thread claim are the known instances.

The overhaul must also name the orphans and their interim status: the shared
`Signal` task surface still exposed by the native platform (define what a
caller gets, or stop exposing it), the reserved task-kind ids in
[protocol/native-protocol.json](../protocol/native-protocol.json), and the
manifest's claim to own "effect" versions when the manifest no longer
contains one. Keeping a concept for the browser is legitimate; keeping it
because deleting prose is work is not.

Settled when: `design.md` states the six principles above (or records the
deliberate alternative), no section contradicts the shipped native
semantics, web-model sections carry an explicit platform scope, and the
outstanding-issues entries written against the old model (action
occurrences, turn ordering, task-name routing) are re-anchored to the new
text.

### 2. Decide the web/native convergence

The largest open call, and the one this branch deliberately deferred. Three
positions are coherent; the design must pick one:

- **Converge on actions.** The pure half is already shared: both hosts
  execute coordinated `UpdateChanges` batches today. `Action.then` is the
  hard half: the native model is *blocking* `!` code on a thread, which the
  browser main thread cannot host. Convergence means designing a browser
  effect executor with the same observable laws — fresh snapshots,
  completion-order application, effects outliving scopes — over an
  asynchronous substrate. That is an architecture problem (where does the
  effectful closure run; what suspends it), not a porting problem, and it
  must not create a second reactive mechanism.
- **Declared divergence.** The action/effect model is native law; the
  browser keeps the task/`Cmd`/`Sub` model as its declared capability set.
  Honest, cheaper, and defensible — native services are genuinely different
  from `fetch` — but it means an author moving between platforms carries two
  mental models for "do something and use the result", leaves two `Http`
  APIs with different error types, and leaves shared modules carrying
  machinery only one platform uses.
- **Ratify the split that already exists.** Coordinated state
  (`Action.update` / `UpdateChanges`) is the shared model on both platforms;
  `then` is a per-platform effect capability the way `Files` already is.
  This is largely a description of the status quo — which is an argument
  for it as the honest interim position, and an argument against mistaking
  it for a decision about the end state.

The decision criteria are already laws: no second reactive mechanism, one
door per platform, bounded cost — and the browser performance-validation
critical path (the row-template experiment of
[issue #39](https://github.com/lukewilliamboswell/roc-signals/issues/39),
with [PR #38](https://github.com/lukewilliamboswell/roc-signals/pull/38)'s
measured construction gap), which this decision must not block, since that
experiment does not depend on effects.

**Direction chosen (2026-09-11): converge on actions — the port is
assumed.** `design.md` now records one action and effect model on both
platforms as the end state: the browser executor consumes the same
queued-thunk contract the native host does and is expected to be small,
with only its substrate (worker execution over shared memory, or stack
suspension around blocking hosted calls) open. The remaining work is the
substrate choice and the port of the web surface, examples, and specs; the
sequencing below governs it.

Settled when: the browser executor exists, preserves the observable laws,
and the interim task vocabulary is removed from the web surface.

### 3. Refine toward explicit cancellation, supersession, and bounds

The rework deleted the answers without deleting the questions. By the
owner's direction these are goals to refine toward, not hard constraints on
the shipped model, and `design.md` now words them as such:

- **Feedback bound.** `design.md` requires a configured consecutive-turn
  bound on effect feedback with useful diagnostics. Native has none: the
  host drains pending effects in an unbounded loop, so a `then` chain that
  keeps returning `then` runs forever — and under the spec host, which
  joins each effect synchronously, that is a synchronous infinite loop in
  the test runner. This is the most direct law-versus-code conflict the
  branch left.
- **Shutdown.** The chooser half is stated and implemented: a window
  closing answers a waiting chooser with `Unavailable`
  ([docs/native-gui-protocol.md](../docs/native-gui-protocol.md)). The rest
  is not: [workers.rs](../crates/gpui-host/src/workers.rs) documents that a
  result posted after the listener stops is dropped — a completed effect's
  writes silently discarded at teardown — and the teardown *order* for
  non-chooser effects (a running `Http.send!` outliving its window) is
  unstated and untested.
- **User-facing cancellation.** The notes editor's documentation shows the
  regression in miniature: "Escape cancels an operation or closes the
  discard confirmation" became "Escape closes the discard confirmation, and
  the native choosers handle their own Escape"
  ([examples-gui/notes-editor/README.md](../examples-gui/notes-editor/README.md)).
  If applications need to abandon an in-flight effect (navigation away from
  a slow request), the answer is either a documented reads-based pattern
  (results of abandoned requests are ignored by the reducer) or a
  primitive. Choose, document, and test the choice; do not leave it to
  example archaeology.
- **Occurrence identity.** The outstanding P1 objective "express action
  occurrences without serial-number encodings" is largely *delivered* on
  native by `Action` — equal events are separate occurrences by
  construction. Claim it: write the acceptance fixtures and close or
  re-scope the entry.

Settled when: each bullet has a stated goal or law in `design.md`, and — as
each refinement lands — a fixture or host test that fails if it regresses,
with the shutdown path exercised.

### 4. Re-aim the capability plan at the hosted-function boundary

[capability-api.md](capability-api.md) was written against the task model.
Its objectives survive unchanged — explicit initial authority, narrow
delegation, host-enforced rights — but its target moved: authority now
enters through hosted `!` functions, and today those grant ambient process
authority (any path via `Files.read_bytes!`, any URL via `Http.send!`, the
whole environment via `Env.var!`) to any code that can run inside an effect.
The capability work should now be framed as: what arguments does `main`
receive, what opaque resources do choosers return, and what does the host
validate before performing a primitive — with the effect boundary, not the
transport, as the enforcement point. An interpreter-style alternative (a
Roc-level task/plan execution model) was prototyped and scrapped without
being committed, so no trace of it exists in history; the objective it
served belongs here, the mechanism does not.

The owner's capability sketch — picker, reader, directory rights,
follow-entry, save target, busy-refusal saves, adapter-enforced no-follow
resolution, and the ordinary-files resource class bounding the confinement
claim — is now ratified in `design.md`'s *Authority and delegated
capabilities*, and `capability-api.md` is re-aimed at the hosted-function
boundary accordingly.

Settled when: `capability-api.md` is revised against the hosted-function
boundary and its work sequence starts from the current `Files` surface.

### 5. Bring the new boundary up to the platform's evidence standard

The effect boundary is currently the least-defended seam in the system:

- The old transport had `EFFECT_VERSION` and size asserts; the new
  `signals_roc_effect_*` / `signals_files_*` / `signals_http_send` surface
  has none, and the protocol manifest no longer carries an effect version at
  all while two documents still say it does. Restore version/layout checks
  before mount, as the node and timer protocols already have, and make the
  manifest claim true again.
- [docs/native-gui-protocol.md](../docs/native-gui-protocol.md) documents
  the Files primitives, per-primitive worker execution, and the chooser
  mailbox contract, but not the `signals_roc_effect_next/run/done` handoff
  or the worker pool's spawn/idle policy. The handoff needs a normative
  section.
- The engine's new failure modes are bare panics — `Then` on a host without
  effects, `Then` without declared reads — and the diagnostics contract
  says a bare trap is a contract violation of the host itself. These, plus
  duplicate batch destinations and an effect result that fails
  preparation, need the structured error-class treatment every other
  contract error gets.
- Concurrency is smoke-tested only: the spec host runs effects serialized,
  so overlap, completion-order races, and reparenting under contention have
  no deterministic regression coverage
  ([test/gui/overlap](../test/gui/overlap)). Decide what the spec host can
  assert (interleaving schedules under a deterministic executor) versus
  what stays in live smoke and focused Rust worker tests, and close the gap
  deliberately.
- `Env.var!` reads the real environment even under specs
  ([src/native_host.zig](../src/native_host.zig)); every other primitive
  stubs. Add the stub so specs stop depending on ambient state.
- Fault placement must extend to the new seams: allocation failure on a
  worker thread, mailbox saturation, effect results arriving during
  teardown, skipped-write observability (principle 3's counter), and the
  invariants that are currently true but unwritten — the UI thread never
  blocks on a worker (the deadlock shape of the chooser mailbox), and the
  cross-thread allocator discipline the hosted primitives rely on.

Settled when: the boundary is versioned, documented, stubbed, diagnosable,
and inside the fault-placement method like every other host seam.

### 6. Finish the API-surface consolidation the props rework started

- The `Elem` tag union now lives in two per-platform copies — a 900-line
  native module and a 62-line web module — that
  [contributing.md](../www/content/docs/contributing.md) instructs
  maintainers to keep tag-for-tag identical, while
  [prepare_platforms.py](../scripts/prepare_platforms.py) `--check`
  validates only the generated shared copies and is blind to `Elem.roc`.
  Enforce the invariant with tooling or restructure so it cannot drift; an
  unenforced identity between two files is how the one-engine claim erodes.
- Decide whether the web platform adopts the props-record model. Product
  Goal 1 does not distinguish platforms; if defaulted props are the
  idiomatic-is-correct answer for native controls, attribute lists on the
  web need either the same treatment or a stated reason to differ.
- Sweep the stale public docs the renames left behind:
  [reference.md](../www/content/docs/reference.md) documents a
  `Files.Error.Canceled` tag that no longer exists, the old value-taking
  `State.write` signature with no mention of `set`, and `Msg` naming.
  (Planning docs are owned by their own objectives: objective 4 revises
  `capability-api.md`; [theming.md](theming.md) gets its attribute-model
  references updated when its own work next touches it.)
- The style-v2 fields from the
  [GUI examples backlog](gui-examples-backlog.md) (weight, alignment,
  per-side padding, container activation) continue on their own track; the
  props rework changed how styles are *written*, not what they can express.

Settled when: parity is machine-checked, the web decision is recorded, and
no maintained public doc describes the pre-rework surface as current.

## Objections considered

The strongest objections to this plan, and where they landed:

1. **"Effects that outlive their scope are a leak by another name."** The
   keep-alive law has no bound: a never-returning effect pins a thread and
   its captures forever, an unbounded `then` chain loops forever, and
   nothing reports either. Conceded — this is why objective 3 treats the
   feedback bound, boundedness, and shutdown as standing goals to refine
   toward, not polish. The leak invariant in `design.md` now names
   reparented effects as owned edges with a diagnosable lifetime.
2. **"Skipping writes to retired states is silent data loss, and the design
   elsewhere forbids silently dropping non-lossy work."** Partly answered
   by precedent: the existing stale-settlement law already drops late
   results for retired owners, and skipped writes are that law's successor.
   What precedent does not cover is *partial application of one batch* —
   the genuinely new semantics — and the fact that today it is invisible.
   Principle 3 therefore demanded an explicit choice, and the overhaul made
   it: observable per-write application, ratified in `design.md`, with the
   observability counter tracked as the follow-up refinement.
3. **"The purity thesis is now false advertising."** Partially conceded:
   `!` code inside effects is effectful Roc in the app's own source.
   Principle 1 is the honest restatement — purity of description and state
   transitions, effects as scheduled continuations — and the thesis text
   must change with it rather than quietly stretching "pure".
4. **"Blocking choosers on workers plus a UI-thread mailbox is a deadlock
   shape."** The worker blocks on a reply channel the UI thread services;
   if the UI thread ever waits on a worker, that is a deadlock. Today it
   does not, but nothing states or tests the invariant. Folded into
   objective 5's fault-placement bullet.
5. **"Convergence on actions may be impossible in Wasm, so objective 2 is
   a fake choice."** Not conceded as impossible — the pure half already
   runs on both hosts, and asynchronous executors with the same observable
   laws are a known design space — but the objection stands as a warning
   against choosing convergence by default because it sounds principled.
   The owner subsequently decided the port is assumed, retiring declared
   divergence as an outcome; what survives of the objection is that the
   executor's substrate must still be designed deliberately, not waved at.
6. **"Objective 1 rewrites the same sections objective 2 defers, so the
   plan decides and postpones the same question."** Conceded and resolved
   by scoping: objective 1 ratifies the native laws and *annotates* the
   web-model sections as platform-scoped pending objective 2; it does not
   settle the task model's fate. The overhaul can therefore land first
   without pre-judging convergence.
7. **"This plan competes with the browser-performance critical path."** No:
   that experiment is browser construction cost and does not depend on
   effects. Objective 1 (truthful design) and objective 5's cheap hardening
   unblock everything else; objectives 2 and 4 are the ones that must not
   preempt the performance work, and the sequence below says so.

## Sequence

1. Objective 1 — the design overhaul, scoped to native laws — first: every
   other decision needs a truthful document to land in, and it is prose
   plus review, not implementation. Fold objective 3's *decisions* (not
   their tests) into it.
2. Objective 5's cheap hardening (version asserts, the `Env` stub, the
   protocol-doc handoff section, structured diagnostics for the bare
   panics) alongside, since it defends the boundary that already shipped.
3. Objective 6's parity enforcement and doc sweep as one mechanical pass.
4. The remaining design work in objectives 2 and 4 — the browser executor
   substrate and web port, and the capability implementation slice — comes
   after the browser-performance gate
   ([issue #39](https://github.com/lukewilliamboswell/roc-signals/issues/39))
   has its evidence, unless that experiment surfaces a reason to move
   earlier. Their directions are already decided and recorded.

## Non-goals

- A Roc-level task/stream interpreter as a second execution model on the
  native platform. Explored in an uncommitted prototype and scrapped; the
  capability objectives it served live in objective 4.
- Numeric budgets in this document. Bounds are objective 3's contracts;
  their numbers belong with the evidence, as
  [design.md](../design.md)'s reading rules require.
- Re-litigating the props-record direction or the styling gap tables; the
  [GUI examples backlog](gui-examples-backlog.md) and
  [theming.md](theming.md) own those.
