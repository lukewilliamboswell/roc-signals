# Roc Signals agent guidelines

## Follow the architectural authority

- Read `design.md` completely before proposing or changing public APIs, signal
  semantics, identity, scopes, ownership, scheduling, effects, rendering, host
  boundaries, wire formats, or lifecycle behavior.
- Treat `design.md` as the authoritative target architecture. The implementation
  may lag behind it; move the implementation toward the design rather than
  treating conflicting current code as precedent.
- Preserve the non-negotiable constraints in `design.md`: no Roc compiler
  changes, no guessing or recovery that changes meaning, work proportional to
  the changed set rather than total graph or tree size, mutation confined to
  the host, structurally safe erased values, and one shared engine behind two
  thin hosts.
- If requested work conflicts with the design, identify the conflict explicitly.
  Do not conceal it in compatibility glue, a special case, duplicated host
  behavior, or an undocumented boundary convention.
- Change `design.md` only for a deliberate change to the intended architecture,
  not to rationalize an implementation shortcut or record the current state of
  unfinished work.

## Protect the reactive model

- Keep the dependency graph explicit Roc data and the mutable runtime in the
  Zig engine. Do not introduce compiler analysis, runtime dependency discovery,
  mutable Roc state, or a second reactive mechanism.
- Preserve glitch-free, dependency-ordered propagation and equality pruning.
  A source update, event, timer, or task result must enter through the same
  propagation model; do not create a side channel that bypasses scheduling,
  pruning, scope ownership, or metrics.
- Treat construction-site identity within a scope and stable keys across list
  rows as semantic contracts. Do not derive identity from content, DOM
  position, native pointers exposed to applications, or a scan of existing
  nodes. Duplicate keys are errors, not aliases.
- Keep dynamic structure owned by explicit scopes. Disposal must detach its
  rendered structure and release every node, closure, effect, task, retained
  value, and host registration owned by that scope.
- Maintain the complexity budget through data structures as well as algorithms.
  Node lookup, identity resolution, dirty scheduling, and descriptor access may
  not hide an O(total graph), O(total tree), or O(total DOM) scan on an update
  path advertised as O(changed).
- Keep rendering a consequence of graph propagation. The browser executor
  applies an already-decided command stream; it must not reconstruct reactive
  meaning, diff application state, or make decisions that belong in the engine.

## Keep erasure and ownership safe

- Treat retained Roc values as opaque capability-owned cells. The host must not
  inspect their layout, infer their type, copy their bytes, or manipulate nested
  reference counts itself; clone, compare, and drop only through the capability
  belonging to that retained edge.
- Preserve the split-and-replace ownership law described in `design.md`: a get
  produces an independently owned value while leaving an independently owned
  value in the source cell. Never model this operation as an untracked borrow.
- Make ownership transitions explicit at every ABI and host boundary. For each
  allocation or retained callable, establish who owns it before the call, on
  success, on refusal, on allocation failure, and during teardown.
- Preflight fallible growth before publishing externally visible commands or
  mutating committed runtime state. A failed command batch, render splice, or
  payload materialization must not expose a partial transaction that cannot be
  retried or cleaned up safely.
- Bound host-retained work and payloads. Define reservation, release,
  saturation, cancellation, and shutdown behavior before adding a queue,
  registry, cache, task class, timer class, or browser bridge.
- Reject programmer and contract errors at the narrowest trustworthy boundary.
  Do not silently repair invalid descriptors, substitute values, discard
  non-lossy work, or continue after state may have become incoherent.

## Preserve one engine and honest boundaries

- Put reactive scheduling, structural reconciliation, identity, effect
  lifecycle, and ownership policy in `src/signals/`. Native and Wasm hosts adapt
  the engine to their environments; they do not independently implement its
  semantics.
- Keep `src/signals/roc_platform_abi.zig` a raw external layout contract. Build
  small borrowed typed views above it rather than spreading offset arithmetic,
  tag interpretation, or host-private meaning through the engine.
- Treat the Wasm command buffer, event payloads, exports, and JavaScript runtime
  as a versioned protocol. Update producer, consumer, validation, tests, and
  user-facing compatibility information together.
- Keep command publication atomic across Wasm memory growth and JavaScript view
  refreshes. JavaScript must not retain stale linear-memory views or observe a
  buffer before the engine has committed its complete contents.
- Preserve the native host as the semantic and observability host and the Wasm
  host as the browser-boundary host. Browser-only behavior belongs in focused
  JavaScript contract tests; shared signal and structure semantics belong in
  the engine and native host tests.

## Complete changes across affected layers

- Trace boundary and public API changes through the Roc platform modules, Zig
  ABI and typed views, shared engine, both hosts, browser runtime, specs,
  examples, generated/bundled artifacts, and maintained documentation wherever
  each layer is affected.
- Read `style.md` before editing Roc. Follow the conventions there for types,
  static-dispatch hooks, builders, errors, strings, and top-level `expect`
  tests; do not duplicate those detailed rules here.
- Follow `www/content/docs/contributing.md` for current setup, test commands,
  coverage, bundles, site builds, releases, and spec mechanics. Commands and
  tool versions belong there because they can change independently of these
  principles.
- Test invariants and failure paths, not only successful output. Cover ordering,
  equality cutoffs, identity reuse, scope disposal, ownership transfer,
  allocation failure, boundedness, retry, cancellation, and protocol rejection
  as applicable.
- Use native semantic specs for application-visible behavior and work budgets,
  focused Zig tests for engine seams and ownership, and JavaScript tests for the
  JS/Wasm contract. Keep semantic locators stable; assert structural work
  exactly and bound incidental engine work as described in the testing docs.
- For performance work, follow `docs/profiling.md`: measure optimized builds,
  test scaling before micro-optimizing, preserve allocator honesty, and validate
  semantics and work counters after the change. Do not trade correctness,
  bounded memory, or architectural clarity for a local benchmark win.
- Preserve unrelated user changes. Keep the requested change focused, and
  report adjacent design or implementation gaps separately rather than folding
  them into an unrequested rewrite.

## Keep documentation truthful and durable

- Keep public behavior consistent across `platform/`, maintained docs under
  `www/content/docs/`, examples, and tests. Documentation examples are part of
  the product surface, not disposable illustrations.
- Put stable architecture and rationale in `design.md`, current contributor
  workflow in the contributing docs, detailed Roc conventions in `style.md`,
  public behavior in reference or module documentation, and local invariants
  beside the code they constrain.
- Review documentation as part of every pull request, including every added or
  changed Zig `pub fn` doc comment. Do not treat satisfying the `///` lint as
  sufficient: each comment must be well written and give a helpful narrative
  explanation of the function's purpose and, where relevant, its contract,
  ownership, failure behavior, or architectural role. Reject comments that
  merely restate the function name or signature without helping a reader
  understand why or how to use it.
- Use `UPSTREAM_COMPILER_BUGS.md` for reproducible compiler limitations. Keep a
  workaround narrow and identifiable; do not let an upstream defect become an
  undocumented platform semantic or weaken the target architecture.

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
