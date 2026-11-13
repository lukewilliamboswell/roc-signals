# Roc Signals agent guidelines

## Follow the architectural authority

- Read `design.md` completely before proposing or changing public APIs, site
  semantics, state (the store, its tables and their table views), identity, scopes,
  propagation, effects, rendering, the host boundary, the wire protocol, the
  spec language, or lifecycle behavior.
- Treat `design.md` as the authoritative target architecture. The implementation
  may lag behind it; move the implementation toward the design rather than
  treating conflicting current code as precedent. Paragraphs marked **Target**
  are design that has not landed, not permission for a different interim
  meaning.
- Preserve the non-negotiable constraints in `design.md`: no Roc compiler
  changes, no guessing or recovery that changes meaning, work proportional to
  the changed set rather than total tree or table size, a pure Roc engine
  behind a host
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
  No engine module imports a hosted function: a job's effects reach the
  engine as values the platform root hands it, which the files and builders
  of that job carry, so the engine also builds as a package
  (`platform/main-fuzz.roc`) for the platform's own fuzz targets. Only the platform-only
  modules (`Files`, `Effects`, `Hosted`, `Cli`) reach the hosts.
- What changed comes from the write. The engine never finds a change by
  comparing a large value with an earlier copy of it: a handler answers the
  set of layers and cells it wrote, and a table's operations record the rows
  they touched. Do not add a site, a cache or a check on an update path that
  keeps the previous value of a state, a cell or a table to compare against.
  A table's changes are this rule at the grain of rows, not a
  second reactive mechanism: they say only which rows a turn wrote, its table views
  are reached by the ordinary `Changed` pass, and they live one turn, cleared
  by the root when that pass has run.
- Dependencies are declared by read signatures on values, the layers and the
  store cells a value reads, built before anything runs. Preserve glitch-free
  propagation: every write of a turn is applied before anything is observed,
  and within a pass order follows nesting. One pass settles everything an
  event wrote on its path: it starts at the outermost write, and a layer
  written below joins it at its own site, for its own subtree, so a reader
  of two written things is evaluated once, after every `derive` above it.
  Do not settle two writes of one event in passes of their own: in either
  order some reader sees one new value beside one old one. Preserve
  equality pruning at holes, rows of a list, `derive`, branch selection, a
  table view's query and window, and effect sites; states, cells and tables do
  not prune on write.
- A turn changes the drawn rows of a table view once. Its site brings the table, the
  query and the window up to date and then applies one comparison of the
  rows drawn before with the window after. Do not apply them as separate
  changes of the rows: a row the turn keeps would be disposed and created
  again, and a row the turn never shows would be created, with its state and
  its requests.
- A DOM event, an effect result and a follow-up enter through the same turn:
  route, fire, settle, Changed pass, end of turn (the changes of the tables
  written are cleared, then focus). Do not create a side channel that
  bypasses routing, pruning, scope ownership, the in-flight table or the
  counters.
- Keep one way to write shared state. A write to a store cell is a value
  (`set`, `update`); a handler or a reaction over cells is a decision, one
  pure function from a reading to a list of writes; and the turn's write set
  is taken from that list. Do not give a handler a static write mask, add a
  per-cell handler or reaction vocabulary beside decisions, or let a decision
  do anything but return its writes. `State` reducers write local state and
  a table view's rows, and `also` composes a local write and a decision into one
  event.
- A cell's getter and modifier are generated from its place in the store's
  description, never written. Do not add an API that takes a getter and a
  modifier from an author: two hand-written lenses can overlap, and a write
  through one then leaves a reader of the other stale with nothing in the
  types to catch it.
- Treat construction-site identity within a scope, exact keys within an
  `each` site and typed keys within a table and its table views as semantic
  contracts. A table view finds its rows by the table's key through the key's own
  equality and hash, never through a text made from it. Do not derive
  identity from content, DOM position, a value's inspected text, or engine
  ids exposed to applications. Duplicate keys are contract errors, not
  aliases. A reference's name is an address the app builds for a command on
  an element, never an identity: rows are found by their keys, and two live
  references with one name are a contract error, not an alias.
- Keep dynamic structure owned by explicit scopes. Disposing a site removes its
  nodes, frees its ids and routes, cancels its subscriptions and timers, and
  reparents its admitted requests to the nearest surviving ancestor, exactly as
  `design.md` specifies. The store is not a scope: a cell lives as long as
  the instance and starts again only by a write.
- A component is a type module: a type, its pure operations, and a view that
  is handed the cells it uses and is generic over the store and its context.
  Only a module that composes components imports the store. Do not give a
  component a context of its own, a fixed environment or a channel upward:
  what it must tell the rest of the app is a write to a cell it was handed,
  or a handler it was handed, run with its own by `also`.
- Maintain the complexity budget through data structures as well as
  algorithms. Event routing, row lookup, refresh and disposal may not hide a
  scan of the whole tree, every site, a whole table or the DOM on a path
  advertised as O(changed). State honestly where an operation is linear, as
  `each` reconciliation is in its list, a table view's rebuild in its table, and a
  move in the drawn rows of a table view.
- Keep rendering a consequence of propagation. The browser runtime applies an
  already-decided command stream and performs requested effects; it must not
  reconstruct reactive meaning, diff application state, or decide anything that
  belongs in the engine.

## Keep ownership and boundaries safe

- Control each failure at the earliest layer of `design.md`'s "How failure
  is controlled" that is reasonably practicable. Do not leave to a check at
  mount a rule the compiler can carry, do not poison at a bound that follows
  an app's data where a refusal or a structural bound is possible, and leave
  nothing to an app's author without stating why and what test catches it.
- Preserve in-place updates. Each piece of state has one holder: exactly one
  closure references a site's storage, the root site alone holds the store,
  and environments move through handlers rather than being shared. No second
  reference is kept for convenience or for comparison; the one earlier state
  the design allows is a table's changes, one earlier row for each row a turn
  wrote, dropped when the turn ends. A change that makes a column, a state, a
  cell or a table copy on every update is a regression even when output is
  correct, and per-event allocation counts and the soak's flat round trips
  must catch it.
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
  answered or cancelled. When a marked batch starts a view transition, effects
  that name no node run and resolve their handles when the call returns, before the
  deferred DOM update. Anything the runtime makes from one (an object URL)
  lives exactly as long as its handle.
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
- Publish atomically. A command batch becomes visible only after its call
  returns; a trap discards it. JavaScript reads command bytes only after the
  call, refreshes memory views after every call that can allocate, and applies
  effects after the whole batch is applied, except that a marked batch starting
  a view transition performs effects that name no node when the call returns.
  Its DOM and node effects follow in the guarded update callback; no page-instance Roc
  call or payload staging may invalidate the waiting command buffer.
- Bound host-retained and in-flight work. Define the bound and the behavior at
  the bound — typed refusal, classified diagnostic, cancellation, teardown —
  before adding a queue, table, request kind, timer class or runtime registry.
  Never silently drop non-lossy work. Input from page JavaScript is external
  input too: a port's answers and messages have a size bound with a typed
  failure, and a subscription declares how its undelivered messages wait and
  what happens beyond that.
- Decide meaning in Roc and limits at mount. What an app means by a request
  (a job's timeout, a call's timeout, how much a read accepts) is decided in
  its Roc code and carried on the request; what a deployment allows is a
  `max…` mount option that caps whatever a request asks for. Do not move an
  app's meaning into a mount option, or a deployment's limit into app code.
- Keep the engine's operations on an exposed type out of an app's reach.
  Roc has no visibility between a module's own and everyone's, so an
  operation an exposed type must offer the engine and must not offer an app,
  such as giving a table its cell's identity, takes an `EngineOnly`: a
  value only a module of the platform can make. Do not add such an
  operation without it, and do not expose the module that makes the value.
- Reject programmer and contract errors at the narrowest trustworthy boundary
  with a classified diagnostic that names the rule and the construction site.
  Do not repair invalid input, substitute values, or continue after state may
  have become incoherent: poison the instance and recover with a fresh one.

## Preserve one engine and honest boundaries

- Put scheduling, reconciliation, identity, effect lifecycle and containment
  policy in `platform/Core.roc` and the platform's Roc modules; a table, its
  table views and their ordered keys are `Table.roc`, `View.roc` and `Seq.roc`. The
  host,
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
  contain nothing specific to an app, an example or the website. JavaScript that
  mounts an app or integrates it with a page lives with that app, example or
  website, and reaches the runtime only through `mountRocEngineApp` and its
  options. That includes port handlers: the JavaScript an app's ports need is
  written with the app and passed at mount. It also includes an example's
  simulated service: the backend an example talks to is that example's own
  JavaScript, kept in its directory and named in `www/data/examples.toml`,
  and the website and the tests load that one file rather than knowing the
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
  models (HTTP, storage, timers, history, focus, workers, files, layout
  observation and media queries) is not a
  port's business.
- Keep observation passive. The runtime's monitor reports what the runtime
  and its pool did after they acted and never decides scheduling, a result
  or an order; everything it keeps is bounded, and an observer that
  misbehaves is dropped rather than obeyed. Meet a measurement need by
  observing more, never by letting an observer steer.
- Treat the command stream, event records, effect payloads, worker payloads,
  port messages, boot bytes and the program's declarations, and
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
  modules, `platform/main.roc` and the engine package root
  (`platform/main-fuzz.roc`), `host.zig`,
  `runtime.mjs`, `worker.mjs`, the native spec runner and oracle, specs,
  examples, generated or bundled artifacts, and maintained documentation
  wherever each layer is affected. A new capability lands whole, as
  `design.md`'s "When a capability is built" lists, with its failure
  analysis and a demonstration in an example or a test app.
- Read the [Roc Style Guide](https://gist.github.com/lukewilliamboswell/241a4e8adb7c89c7e0e02f1d303a8fa1)
  before editing Roc. Follow it for naming, types, props records, function
  shape, errors, text, the host boundary and top-level `expect` tests; do not
  duplicate those detailed rules here. It is shared across Roc projects, so
  this repository keeps no style document of its own.
- Follow `www/content/docs/contributing.md` for current setup, tasks, test
  commands, bundles, website builds, releases and spec mechanics. Commands and tool
  versions belong there and in `Blueprint.roc`, because they change
  independently of these principles. Automation is Roc scripts under
  `scripts/`, invoked through Blueprint tasks.
- Test invariants and failure paths, not only successful output. Every
  reader of a layer or a cell a turn wrote is refreshed in that turn, and
  every table view equals one built from scratch: the native spec
  runner, its walks and every fuzz target that drives the engine check
  both after each step (`Core.settled`), and a change to propagation, to a
  table or to a table view must keep that check meaningful. Cover
  ordering, two writes of one event met together by a reader of both (in
  both directions: a `derive` of the outer write, and of the inner one),
  equality cutoffs, identity reuse, scope disposal, reparenting,
  a decision's write set and its same-cell rule, a reset, keyed writes and
  whole rewrites of a table, changes of a table view's query and window, an event
  that writes several of a table view's table, query and window,
  refusal at the in-flight bound, stale results, cancellation and
  supersession, lost and timed-out work, a task's own failure, eviction and
  the loss of a worker holding state, a builder kept past its call,
  the release of a handle, a file the browser can no longer
  read, follow-up bounds, containment and recovery, and protocol rejection
  as applicable.
- Keep decisions pure and test them as functions. A transition across cells
  is checked by a top-level `expect` over `Store.after` and `Store.read`,
  with no engine and no browser. That test, not the engine, is what sees a
  transition that left out a reset or wrote the wrong cell of the right
  type.
- Use `.scm` specs beside each app (`examples/<app>/specs/`,
  `tests/apps/<app>/specs/`) for application-visible behavior and work, run
  natively and in Chrome, with each app's round trip as a spec the native
  runner soaks (`--soak`); the native runner's seeded walk of each app
  (`--walk`, run by the repository's scripts over the app's ordinary
  `main.roc`) for long leak-checked sessions of real apps; the platform's
  roc-fuzz targets (`fuzz/`, and those beside test apps under
  `tests/apps/`), ordinary roc-fuzz apps on the engine package, for engine
  sequences checked against a model; and contract cases under `tests/` for
  `host.zig`, `runtime.mjs` and `worker.mjs` against the wire protocol.
  Keep semantic locators stable and assert structural work exactly.
- Keep platform tests out of the examples. An example holds what an app
  author would write: its modules, `main.roc`, its specs, its own
  JavaScript and, where its pure logic has a rule worth stating, a roc-fuzz
  target of that logic named for what it checks (`fuzz-<subject>.roc`)
  that imports nothing of the platform. Nothing in an example exists only
  so a platform test can drive it, and no public API exists only for one.
- Reach for fuzzing where the bug class is a *sequence* rather than a case:
  reconciliation order, identity reuse across disposal, effect lifetime across
  disposal and reparenting, a table view kept from a long history of keyed writes,
  rewrites and window changes, allocation balance over a long history. Targets are
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

- Use one vocabulary throughout the public API and maintained prose. A signal
  declares its reads; a view is UI, and a table's is a table view. A row is
  table data and a drawn row is its scope on the page. A table keeps a turn's
  changes; a record is Roc data or a wire record. Cells are cells; handles
  name browser objects. A context is a type and a scope is a lifetime. Use
  turn, not transaction; result for any request outcome and answer for one
  the other side produced. Keep layer and a site's storage as engine terms;
  user guides say signal, and storage there means the browser's.

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
