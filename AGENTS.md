# Roc Signals agent guidelines

## Follow the architectural authority

- Read `design.md` completely before proposing or changing public APIs, site
  semantics, identity, scopes, propagation, effects, rendering, the host
  boundary, the wire protocol, the spec language, or lifecycle behavior.
- Treat `design.md` as the authoritative target architecture. The implementation
  may lag behind it; move the implementation toward the design rather than
  treating conflicting current code as precedent. Paragraphs marked **Target**
  are design that has not landed, not permission for a different interim
  meaning.
- Preserve the non-negotiable constraints in `design.md`: no Roc compiler
  changes, no guessing or recovery that changes meaning, work proportional to
  the changed set rather than total tree size, a pure Roc engine behind a host
  that only allocates, stages payloads, backs handles and classifies
  faults (and, in a worker instance, performs a job's hosted effects on
  handles), typed site storage with no host-held Roc values beyond the opaque
  boxes `design.md` names (the page's engine state, and one prepared state in
  a worker instance), and the command stream as the page instance's only
  output.
- If requested work conflicts with the design, identify the conflict explicitly.
  Do not conceal it in compatibility glue, a special case, logic in the host or
  runtime, or an undocumented boundary convention.
- Change `design.md` only for a deliberate change to the intended architecture,
  not to rationalize an implementation shortcut or record the current state of
  unfinished work.

## Protect the reactive model

- Keep the engine in pure Roc in `platform/`. Every dynamic site is one closure
  that owns its typed storage and answers `Fire`, `Changed` and `Dispose`. Do
  not introduce a node table, a value registry, runtime dependency discovery,
  host-side state, or a second reactive mechanism.
- Dependencies are declared by read masks on values, built before anything
  runs. Preserve glitch-free propagation: all writes of a turn are applied
  before the single observation pass, and order follows nesting. Preserve
  equality pruning at holes, rows, `derive`, branch selection and effect sites.
- A DOM event, an effect result and a follow-up enter through the same turn:
  route, fire, settle, Changed pass, end-of-turn focus. Do not create a side
  channel that bypasses routing, pruning, scope ownership, the in-flight table
  or the counters.
- Treat construction-site identity within a scope and exact keys within an
  `each` site as semantic contracts. Do not derive identity from content, DOM
  position, or engine ids exposed to applications. Duplicate keys are contract
  errors, not aliases.
- Keep dynamic structure owned by explicit scopes. Disposing a site removes its
  nodes, frees its ids and routes, cancels its subscriptions and timers, and
  reparents its admitted requests to the nearest surviving ancestor, exactly as
  `design.md` specifies.
- Maintain the complexity budget through data structures as well as
  algorithms. Event routing, row lookup, refresh and disposal may not hide a
  scan of the whole tree, every site, or the DOM on a path advertised as
  O(changed). State honestly where an operation is linear, as `each`
  reconciliation is in its list.
- Keep rendering a consequence of propagation. The browser runtime applies an
  already-decided command stream and performs requested effects; it must not
  reconstruct reactive meaning, diff application state, or decide anything that
  belongs in the engine.

## Keep ownership and boundaries safe

- Preserve in-place updates. Exactly one closure references a site's storage;
  environments move through handlers rather than being shared; no second
  reference is kept for convenience. A change that makes a column or state copy
  on every update is a regression even when output is correct, and the soak's
  flat round trips must catch it.
- Keep the host to its job. `host.zig` holds one opaque boxed engine state (in
  a worker instance, at most one opaque boxed prepared state instead), the
  last command buffer, at most one staged payload, the typed heaps behind
  handles, the allocator and the fault state, and in a worker
  instance the flag that says a job (or a preparation) is running. It clears
  its slots before each call into Roc and never interprets the state, the
  commands or any Roc value. A job's hosted effects are the platform's closed
  vocabulary: exported host functions that refuse to act outside a job and
  each call one import of the worker script, which holds the browser objects;
  the host itself holds no builder, part or browser object. A box moves whole into one Roc call and back out of it, and only
  Roc drops it; a trap abandons it with the heap. Lay out staged lists exactly
  as Roc expects and never hold a seamless slice.
- Keep browser objects behind handles Roc owns. Something the browser holds,
  such as a user's file, reaches Roc as a handle the host mints in a typed
  heap. Roc's reference count is the handle's lifetime: the host learns of
  the last release when Roc frees it, never holds a handle itself, and lets
  JavaScript release the browser object only after the call's batch and
  effects, which may still name it. Do not replace this with tokens an app
  must release, a registry the host scans, or bytes copied through the page
  to avoid a handle. Operations on a handle are requests that take it and
  act where the browser object lives; its contents cross into Wasm only
  through a read the app asks for. A request resolves the handle to its
  browser object when its batch is applied and holds it until it is
  answered or cancelled, and anything the runtime makes from one (an object
  URL) lives exactly as long as its handle.
  Handles cross between instances by token: each instance mints its own box
  for the browser object, so either side letting go cannot invalidate the
  other's. A file a job builds is immutable once finished, and its builder
  never outlives the call that opened it, so nothing a stopped or failed job
  wrote is ever observable and no job sees what an earlier one wrote except
  through a finished file.
- Make ownership explicit at the boundary. For each list that crosses it (boot
  bytes, payloads, command buffers, key lists, handle lists, a job's input
  and answer, a file read into the page as a result), establish
  who owns it before the call, after it, and when the instance is poisoned or
  dropped.
- Publish atomically. A command batch becomes visible only when its call
  returns; a trap discards it. JavaScript reads command bytes only after the
  call, refreshes memory views after every call that can allocate, and applies
  effects only after the whole batch is applied.
- Bound host-retained and in-flight work. Define the bound and the behavior at
  the bound — typed refusal, classified diagnostic, cancellation, teardown —
  before adding a queue, table, request kind, timer class or runtime registry.
  Never silently drop non-lossy work. Input from page JavaScript is external
  input too: a port's answers and messages have a size bound with a typed
  failure, and a subscription declares how its undelivered messages wait and
  what happens beyond that.
- Decide meaning in Roc and limits at mount. What an app means by a request
  (a job's deadline, a call's timeout, how much a read accepts) is decided in
  its Roc code and carried on the request; what a deployment allows is a
  `max…` mount option that caps whatever a request asks for. Do not move an
  app's meaning into a mount option, or a deployment's limit into app code.
- Reject programmer and contract errors at the narrowest trustworthy boundary
  with a classified diagnostic that names the rule and the construction site.
  Do not repair invalid input, substitute values, or continue after state may
  have become incoherent: poison the instance and recover with a fresh one.

## Preserve one engine and honest boundaries

- Put scheduling, reconciliation, identity, effect lifecycle and containment
  policy in `platform/Core.roc` and the platform's Roc modules. The host,
  `runtime.mjs` and `worker.mjs` adapt the engine to the browser; they do not
  implement its semantics. The native spec runner drives the same engine; it
  does not simulate a different one.
- Keep page code pure and the compiled module the unit of compatibility.
  A worker runs a registered task in another instance of the same module,
  and its request and answer are an ordinary request and result in the
  effect channel; there is one kind of worker function and one request
  kind. A task's `run!` may be a pure calculation or call the platform's
  hosted effects on the handles its job was sent or made, and nothing
  else; a preparation's `prepare!` likewise, and its answer must be a
  function of its input. The runtime's pool places, bounds and stops jobs;
  it never changes an answer or decides anything that belongs to the
  engine. A worker may keep a preparation's state between jobs, but only as
  an optimisation that is never observable in an answer: a job's answer is
  what preparing afresh and running the task would give, tasks never change
  the state, and placement, eviction or a lost worker cost only time. A
  task's own failure is its answer (`Failed`), never confused with a lost
  job. Both spec runners run a job's task, and serve its hosted effects
  from the same files, so a spec means the same in each.
- Keep the platform's JavaScript generic. `runtime.mjs` and `worker.mjs`
  contain nothing specific to an app, an example or the site. JavaScript that
  mounts an app or integrates it with a page lives with that app, example or
  site, and reaches the runtime only through `mountRocEngineApp` and its
  options. That includes port handlers: the JavaScript an app's ports need is
  written with the app and passed at mount. It also includes an example's
  simulated service: the backend an example talks to is that example's own
  JavaScript, kept in its directory and named in `www/data/examples.toml`,
  and the site and the tests load that one file rather than knowing the
  example or keeping a copy. JavaScript several examples load lives in
  `examples/shared/`, never in the platform. The script the `signals.roc`
  tool's development server adds to a page (reload on a rebuild, an overlay
  for errors) is the tool's own, kept in `cli/`: it only watches what the
  page and the runtime report, is added as the page is served rather than
  written into an app's files, and never reaches the platform or a built
  `dist/`. A port is a named request kind
  of the effect channel, not a way around it: its JavaScript performs one
  request and answers with data, checked against the type the app declared;
  it never decides reactive meaning, never touches the DOM the engine owns,
  and never calls into Roc or holds a Roc value. A service the platform
  models (HTTP, storage, timers, history, focus, workers, files) is not a
  port's business.
- Keep observation passive. The runtime's monitor reports what the runtime
  and its pool did after they acted and never decides scheduling, a result
  or an order; everything it keeps is bounded, and an observer that
  misbehaves is dropped rather than obeyed. Meet a measurement need by
  observing more, never by letting an observer steer.
- Treat the command stream, event records, effect payloads, worker payloads,
  port messages, boot bytes (with the port table after the storage keys) and
  Wasm exports as one versioned protocol. Change the Roc encoder
  and decoders, `platform/Dom.roc`, both hosts (`host.zig`, `spec.zig`),
  `runtime.mjs`, `worker.mjs`, the contract tests in `tests/` and Appendix B of
  `design.md` together.
- Keep `platform/Dom.roc` independent of the engine. It is the oracle; code
  shared with `Core.roc` would let one bug pass its own test.
- Keep `.scm` specs the single source of truth for application-visible
  behavior, parsed by the one Roc parser in `platform/Scm.roc`. Unknown steps are
  hard errors in every runner. The native runner builds for several systems
  and means the same on each: what differs between them is a service of the
  native host's system files (`platform/host/os_posix.zig`,
  `platform/host/os_windows.zig`), never a difference in what `spec.zig`
  or the Roc runner does, and a crashing worker job stays lost work on
  every system. Do not weaken, skip or reinterpret a step to make
  it pass; a reinterpretation is a design change recorded in `design.md` and in
  the commit.

## Complete changes across affected layers

- Trace boundary and public API changes through the engine, the typed view
  modules, `platform/main.roc` and the fuzz platform root, `host.zig`,
  `runtime.mjs`, `worker.mjs`, the native spec runner and oracle, specs,
  examples, generated or bundled artifacts, and maintained documentation
  wherever each layer is affected.
- Read the [Roc Style Guide](https://gist.github.com/lukewilliamboswell/241a4e8adb7c89c7e0e02f1d303a8fa1)
  before editing Roc. Follow it for naming, types, props records, function
  shape, errors, text, the host boundary and top-level `expect` tests; do not
  duplicate those detailed rules here. It is shared across Roc projects, so
  this repository keeps no style document of its own.
- Follow `www/content/docs/contributing.md` for current setup, tasks, test
  commands, bundles, site builds, releases and spec mechanics. Commands and tool
  versions belong there and in `Blueprint.roc`, because they change
  independently of these principles. Automation is Roc scripts under
  `scripts/`, invoked through Blueprint tasks.
- Test invariants and failure paths, not only successful output. Every
  reader of a layer a turn wrote is refreshed in that turn: the native spec
  runner and every fuzz walk check it after each step (`Core.settled`), and
  a change to propagation must keep that check meaningful. Cover
  ordering, equality cutoffs, identity reuse, scope disposal, reparenting,
  refusal at the in-flight bound, stale results, cancellation and
  supersession, lost and timed-out work, a task's own failure, eviction and
  the loss of a worker holding state, a builder kept past its call,
  the release of a handle, a file the browser can no longer
  read, follow-up bounds, containment and recovery, and protocol rejection
  as applicable.
- Use `.scm` specs beside each app (`examples/<app>/specs/`,
  `tests/apps/<app>/specs/`) for application-visible behavior and work, run
  natively and in Chrome; roc-fuzz targets (each app's `main-fuzz.roc`, and
  `fuzz/` for the shared support) for engine sequences and leak-checked soaks;
  and contract cases under `tests/` for `host.zig`, `runtime.mjs` and
  `worker.mjs` against the wire protocol. Keep semantic locators stable and
  assert structural work exactly.
- Reach for fuzzing where the bug class is a *sequence* rather than a case:
  reconciliation order, identity reuse across disposal, effect lifetime across
  disposal and reparenting, allocation balance over a long history. Targets are
  generators that decode arbitrary bytes into a valid program and check it
  against a reference model, so their oracles, not their inputs, carry the
  value. When a campaign (`blueprint run fuzz`) catches a bug, minimize the
  input and add it to the target's examples with `Fuzz.saved`, so every
  replay keeps the fix fixed.
- Judge a fuzz target by its properties: state the rules the engine must keep
  over generated sequences and check them against a reference model.
- For performance work, follow the performance section of the contributing
  docs: measure optimized builds,
  test scaling before micro-optimizing, keep allocator counters honest, and
  validate semantics and counters after the change. Do not trade correctness,
  bounded memory or architectural clarity for a local benchmark win.
- Preserve unrelated user changes. Keep the requested change focused, and
  report adjacent design or implementation gaps separately rather than folding
  them into an unrequested rewrite.

## Keep documentation truthful and durable

- Keep public behavior consistent across `platform/`, maintained docs under
  `www/content/docs/`, examples, and specs. Documentation examples are part of
  the product surface: every Roc sample is a file under `www/samples/` that
  `check` compiles, never an inline block.
- Put stable architecture and rationale in `design.md`, current contributor
  workflow in the contributing docs, detailed Roc conventions in the Roc Style
  Guide,
  public behavior in reference or module documentation, and local invariants
  beside the code they constrain.
- Review documentation as part of every pull request, including every added or
  changed doc comment on an exposed Roc function and every Zig `pub fn` or
  `export fn`. Each comment must be well written and give a helpful narrative
  explanation of the function's purpose and, where relevant, its contract,
  ownership, failure behavior, or architectural role. Reject comments that
  merely restate the name or signature.
- Track reproducible compiler limitations in upstream GitHub issues. Once
  filed, link the issue beside any local workaround, keep the workaround narrow
  and identifiable, list it in `design.md`'s compiler limitations, and remove it
  once the pinned compiler contains the fix. Do not let an upstream defect
  become a platform semantic or weaken the target architecture.

## Keep this file enduring

- `AGENTS.md` contains repository-wide principles and review guardrails only.
  It is not a notebook, changelog, roadmap, task tracker, handoff document, or
  memory store.
- Do not add issue or pull-request status, implementation progress, temporary
  workarounds, investigation logs, benchmark snapshots, command transcripts,
  current compiler failures, one-off file instructions, TODO lists, or lessons
  that expire when a particular task is complete.
- Track active priorities, status, spike results, and task discussion in issues
  or pull requests. Temporary local notes may support a spike, but must be
  removed before merge after enduring conclusions have been folded into their
  proper authoritative location.
- Add or change an instruction here only when it should govern unrelated future
  work across the repository. If it is likely to expire with one feature, bug,
  release, or tool version, it does not belong here.
