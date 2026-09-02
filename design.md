# Signals UI Platform — Target Design

This document is the single authoritative design for the Signals UI platform. It
describes the architecture we are building toward and the invariants every part
of it must hold. It is forward-looking and enduring: it describes the system as
it is meant to be, not the current state of a work queue. Live work tracking
belongs in issues and pull requests.

## Thesis

Roc Signals exists so that a Roc developer can build an interactive browser UI
in pure Roc and trust it the way they trust the rest of their Roc code: values
in, values out, no hidden mutable runtime in the app, and every behaviour
checkable before it reaches a browser. The app describes its UI as data — a
descriptor tree whose dependency edges are already explicit in the structure
of each `map`/`map2`/record-builder call — and hands that description to a
host-owned engine once. From then on, the engine re-runs only the closures
whose inputs changed, in dependency order, and emits only the DOM commands
those changes imply. There is no virtual DOM and no per-event re-render; work
is proportional to what changed, and that claim is enforced by counters a spec
can assert, not by benchmarks a reviewer has to trust.

The one-sentence wedge: **pure Roc, no VDOM, O(changed) updates, and every
behaviour provable in a fast native test before it ever touches a browser.**

It is for Roc developers building interactive browser applications — dashboards,
editors, forms, routed multi-page apps such as Conduit. It is not a general
replacement for the JavaScript ecosystem, not a UI toolkit for other languages,
and not a server-rendering platform.

## Product Goals (author-facing)

These are the requirements, and they are principles rather than tasks: each is
a property the platform must hold for its whole life, from which every
mechanism, spec, and maintained app derives. Gaps between this document and
the implementation are tracked in issues, never here. The *Success Criteria* below say how each
principle is observed; this section says what it is.

1. **The idiomatic way is the correct way.** The simplest thing an author can
   write must be the thing the platform is designed for. If the natural
   expression of a UI shape needs an encoding trick, a positional convention, or
   hand-written boilerplate the compiler could derive, the platform is wrong,
   not the author. Workarounds are defects of the platform's API.

2. **Composition is first-class.** UI is built from typed, reusable units that
   take inputs and children, own their local state and effects, and can be
   published and imported as ordinary Roc packages. An application decomposes
   by feature into modules; nothing in the platform forces structure into one
   place.

3. **The scaling promise holds for apps, not just the engine.** Work
   proportional to the changed set is a property authors get by writing
   idiomatic code, not one they must engineer around the engine. Where a
   natural idiom would defeat it, the platform provides the primitive or the
   documented pattern that restores it, and the property is pinned by
   observable work counters.

4. **Failure is legible.** Every contract violation — in a descriptor, a key, a
   capability, a payload, a budget — is reported to the author as a readable
   diagnostic naming the construction site and the rule broken, identically
   under the native runner and in the browser. A bare trap, an integer code, or
   a silent no-op is never an acceptable way to fail.

5. **There is exactly one door to the outside.** Everything that crosses to
   JavaScript — events, tasks, browser sources, and third-party integration —
   travels through the same declared, scope-owned, typed boundary vocabulary.
   No globals, no second payload format, no runtime edits per app.

6. **Cost is visible and bounded.** Payload size, startup, and per-event work
   are measured, budgeted, and enforced continuously, so an author can reason
   about what an app costs before shipping it and a regression cannot land
   silently.

7. **Provable before it reaches a browser.** Any behaviour an author cares
   about — semantics, ordering, work done, cleanup — can be asserted in a
   fast, deterministic native test in user-facing terms. The browser is where
   the app runs, never where its correctness is first discovered.

8. **Approachable and honest.** A developer who knows Roc can learn the model
   from the documentation alone, and what the documentation says is what the
   platform does. Real applications are not more verbose than their
   equivalents on mature frameworks.

## Success Criteria

Success is judged in three tiers. Tier 1 is necessary and is where most of the
engine investment lands, but **Tier 1 alone cannot declare success**: an engine
that satisfies every invariant while no one can write an app against it has
failed. Tiers 2 and 3 are the externally visible outcomes the engine exists
to deliver.

**Tier 1 — Engine invariants.** The properties listed under *Measures of
Effectiveness* below (one engine, two thin hosts; same apps in both
environments; semantics proven on the native host; work scales with change;
deterministic reclamation with no leaks; determinism; confined erasure cannot
crash), plus the known-failure ratchet reaching zero entries and staying there.
*Evidence:* native specs with `expect_metric_delta`, host tests, fault
placement, fuzz targets, the ratchet file.

**Tier 2 — Author outcomes.** Each product goal has a standing measurement:

- *Idiomatic is correct:* the count of workaround sites in the maintained
  suite (encodings through keys, positional readbacks, derivable boilerplate)
  is zero.
- *Composition:* a maintained app factors a repeated fragment into a typed,
  packaged unit; a fixture proves inputs, children, and scoped state.
- *Scaling for apps:* a one-row change in the large keyed fixtures runs O(1)
  Roc closures, pinned by `expect_metric_delta` on `derived_calls_into_roc`.
- *Legible failure:* one fixture per contract-error class asserts the
  diagnostic text and site attribution on both hosts.
- *One door:* an interop canary integrates a third-party widget through the
  declared boundary only.
- *Bounded cost:* gzipped Wasm and runtime sizes and time-to-interactive for
  the counter fixture and Conduit are CI floors, ratcheted like coverage.
- *Provable first:* every maintained app's behaviour spec runs natively; JS
  tests cover only the boundary contract.
- *Approachable:* a developer new to the repository reaches a deployed counter
  from the getting-started docs in a bounded, recorded time; Conduit is within
  roughly 1.3× the application line count of the Elm and Solid RealWorld
  implementations.

**Tier 3 — External evidence.** Proof that is legible to people who have not
read this document:

- A keyed `js-framework-benchmark` submission with stated targets — no worse
  than 1.5× vanilla JavaScript on the nine table operations, and startup and
  memory within the range of the compiled-language entries.
- Conduit passing a real-browser end-to-end run (Playwright) against the
  RealWorld specification, not only the native spec suite and the DOM double.
- Gzipped Wasm and runtime size budgets enforced as CI floors.

## Non-Goals

Stating what is out of scope is part of the design. Each item below is a scope
decision with the condition under which it would be reconsidered; none is an
omission.

- **Server-side rendering, hydration, prerendering, and SEO.** The platform is
  a client-side runtime. Reconsidered only once Tier 3 evidence exists for the
  client story. Any server path must keep the command stream as the only
  render output and must not introduce a second reactive mechanism: hydration
  would be the engine adopting existing DOM ids, never JS reconstructing
  meaning.
- **Multiple roots per Wasm instance.** One mount owns one instance; roots are
  isolated by instance, not by handle. Reconsidered only if many-widget
  embedding measurements show per-instance memory or startup cost is
  unacceptable (see *Open Questions*).
- **Out-of-memory recoverability beyond trap-and-remount.** The engine keeps
  preparation fallible and publication allocation-free so a failed transaction
  never exposes a partial generation, and *Memory management and allocation
  failure* is authoritative for that containment. Resuming a poisoned instance
  or making every callback boundary recoverable is not a goal: the browser's
  own answer to exhaustion is to reload, and the platform's answer is a fresh
  instance. Reconsidered only if the Roc callback ABI gains explicit failure
  and ownership-unwind semantics.
- **A general-purpose JavaScript FFI.** Apps do not call arbitrary JavaScript.
  Integration goes through the single declared door (see *One door to
  JavaScript*). Reconsidered never; a use the door cannot express is a reason
  to extend the door's typed vocabulary, not to bypass it.

### Traceability

Every later section of this document, every spec, and every maintained app
must be able to say which product goal or Tier 1 invariant it serves. A
proposed design change that serves no goal is out of scope, however elegant;
a goal with no section, spec, or app serving it is a gap to close, not a
sentence to delete.

## Purpose and Dual-Host Architecture

The thesis and product goals above are the requirements; the engine described
from here on is the means. The product is built on a **host-agnostic reactive engine**: a mutable node table,
topological-rank scheduler, dirty set, `is_eq` value pruning, scope forest,
keyed-row diff, identity tables, and structural splice/collect/apply. The engine
owns all reactive and structural logic. It is the single source of truth for how
a Signals app behaves.

The engine is driven by **two thin hosts** that implement one contract — a
`Ctx` (host capabilities the engine calls) plus a `sink()` (where the engine
writes render commands). The hosts differ only in their boundary, never in their
reactive behaviour:

- **Native host** — the spec/telemetry/debug host. It backs the engine with a
  simulated DOM (a flat `DomElement` array), a semantic-locator spec runner, an
  allocation ledger, and fine-grained work counters. It compiles to a native
  binary, so ordinary tooling (`lldb`, allocation tracing) can inspect crashes
  and memory behaviour directly. Its job is **low-level observability and
  semantic assertion** — the things a real browser cannot show us.

- **Wasm host** — the browser-boundary host. It backs the engine with a
  command-buffer sink serialized into linear memory, plus the JS↔WASM boundary:
  UTF-8 marshalling, event-payload codec, `memory.grow` view coordination, and
  timer/`fetch` bridges. Its job is **the JS↔WASM contract only**. It contains
  no reactive or structural logic; that all lives in the engine.

The same Roc apps compile against both hosts. The native spec runner asserts
semantics and work budgets; the browser runs the apps for real. The JS runtime
is a thin executor of the engine's already-computed command stream — it never
reconstructs meaning, holds reactive state, or re-decides patches.

```mermaid
flowchart LR
    App["Roc application"] --> Platform["Roc platform<br/>descriptor tree · typed retained closures"]
    Platform -->|"roc_ui_init once;<br/>direct closure calls thereafter"| Engine["shared Engine(Ctx)<br/>reactivity · structure · ownership · rendering decisions"]

    Engine <-->|"Ctx + sink contract"| Native["native host"]
    Native --> NativeSurface["simulated DOM<br/>spec runner · metrics · allocation ledger"]

    Engine <-->|"Ctx + sink contract"| Wasm["Wasm boundary host"]
    Wasm --> Wire["atomic command and payload buffers<br/>in linear memory"]
    Wire --> JS["JavaScript decoder and executor"]
    JS --> Browser["browser DOM and resources"]
    Browser -->|"events · timers · task results"| JS
    JS -->|"validated integer and byte payloads"| Wasm
```

## Non-Negotiable Constraints

These constraints come from the platform's role and from the discipline this
document is meant to preserve. Every part of this design must respect them.

1. **No compiler changes.** This is a platform. We may not add dataflow
   analysis passes, dependency-graph extraction, or any new compiler behavior.
   Everything is ordinary Roc plus a Zig host.
2. **No workarounds, fallbacks, heuristics, or best-effort recovery** outside of
   parsing and error reporting. The host never *guesses* what changed, never
   scans to rediscover identity, and never reconstructs missing information. It
   consumes explicit data produced by the Roc graph description.
3. **Work scales with the number of changed nodes, not with tree size.** This is
   the entire point of signals. Per event, the host re-invokes only the Roc
   transform closures whose inputs actually changed, in dependency order. There
   is no full-tree re-walk and no full re-render per event. **This constraint
   binds the data structures, not just the algorithm.** A path that is "linear in
   the changed set" on paper but reaches that set through a linear scan of all
   nodes, a linear pointer→id lookup, or a full graph rebuild is a violation, not
   an implementation detail. Identity→id resolution, descriptor lookup, and
   dependency-graph maintenance must be O(1) or O(changed), never O(total). See
   *Complexity Discipline* below for the precise budget every code path owes.
4. **Mutation lives only in the host.** Roc is pure and value-oriented. The
   reactive runtime — the dirty set, the scheduler, the in-place node table — is
   intrinsically mutable, so it lives in the Zig engine/host, which is the one
   place mutation is legal.
5. **Type-mismatch crashes are structurally impossible.** A typed `Signal(a)`
   stays typed end to end. Erasure is confined to one generated set of ownership
   operations per edge — a **capability** bundling clone, equality, and drop,
   with typed split private to those operations and edge-specific extension
   records carrying their owning capability — pinned to that edge's
   monomorphized types. There is no host-authored read site that can disagree
   with the writer, and no host-side knowledge of the value's layout. See
   *Confined Erasure*.
6. **One engine, two thin hosts.** All reactive and structural logic lives in the
   shared engine. A host file contains only its boundary (sink, marshalling,
   spec runner / JS bridge) and its `Ctx` implementation. Reactive or structural
   logic appearing in a host file is a defect: it lets the two hosts diverge,
   which this architecture exists to prevent.

## First Principles, Not Imitation

We are not porting Solid, Elm, or Incremental to Roc. We are deriving the model
that *fits Roc* — a pure, value-oriented language with no mutable globals, no
ability auto-derivation, and a hard "no compiler changes" rule. Those three
frameworks are useful reference points for what works and what does not, but the
design below follows from Roc's constraints, not from any of them.

The reference points:

**Elm** rebuilds the view and diffs per event. That is O(view size) per event
and is the opposite of signals. We reject the *mechanism* (per-event re-render),
not the discipline — Elm's "pure description of UI, effects as data" is exactly
the shape we keep.

**Solid** discovers dependencies by *running* effects and watching reads through
a mutable global "current observer." Its great strength is precise, lazy edges:
a node that conditionally reads `B` only depends on `B` while it actually reads
it. Roc cannot observe its own reads and has no mutable globals, and we cannot
add compiler support to fake it. So we cannot copy Solid's *mechanism*.

**Jane Street's Incremental / Adapton** are the honest lineage of what we *can*
build: an explicitly-constructed dependency graph, a topological-rank scheduler,
and a value cutoff (`is_eq`) that stops propagation when a recomputed value is
unchanged. This is push-based incremental computation over a graph the program
declares rather than one the runtime discovers.

**The reframing that makes signals work in pure Roc:** in Solid, dependencies
are *discovered* at runtime. In a pure language, dependencies are *declared* —
they are already present in the structure of each `map`/`map2`/`combine` call,
or in Roc record-builder syntax such as `{ price: price, qty: qty }.Signal`,
before anything runs. When the app writes a two-input derived signal, the edges
`price -> result` and `qty -> result` are *data*. So the host never needs a
current-observer stack and never runs a closure to find out what it reads. The
**dependency graph is handed to the host as a value, once.** The host then owns
a mutable node table and runs push-based incremental propagation over it.

This is "the graph is Roc data, the runtime engine is the host." It keeps
signals' linear-with-changes scaling, fits Roc's purity, and needs zero compiler
changes.

**The tradeoff we accept, stated plainly.** Declared edges are *eager*, not
lazy. A node that depends on `{cond, A, B}` to express `if cond then A else B`
stays subscribed to all three; when `cond = true` and only `B` changes, the host
still wakes the node and runs its transform, and `is_eq` pruning only suppresses
the *output* after the work is done. Solid would not wake the node at all. We
accept this because the alternative — lazy, read-tracked edges — requires
observing Roc's reads, which the no-compiler-changes rule forbids. The escape
valve for genuinely dynamic dependency *structure* (a derivation over a
value-dependent set of inputs) is the same scope mechanism that powers `Ui.each`
(see Identity and Dynamic Structure): a sub-graph that is rebuilt when its shape
changes, not a static edge that is always live. Dynamic-cardinality reactivity
and dynamic list structure must therefore share one mechanism, never two.
The same eagerness has an app-level consequence: a single coarse `Model` state
with many `map` projections wakes every projection on every change, so the
idiomatic state shape can defeat the scaling claim even when the engine honours
it. Product Goal 3 (the scaling promise holds for apps) owns the answer, and
the design supplies both halves: `Signal.select` for keyed membership, and the
partitioning rule that independent concerns are independent signals (row-local
`Ui.state`, one signal per field that changes on its own) rather than
projections of one coarse record.

## Core Concepts

- **Signal(a)** — a continuous, always-present value of type `a`. Opaque typed
  descriptor that references a source binder or derived expression. The `a`
  exists only in Roc's type system; the host assigns the runtime node id when it
  ingests the descriptor tree.
- **Source** — a node whose value is set by host input (a DOM event, a timer, an
  effect result). Local state sources are introduced by the `Ui.state` closure
  binder; effect combinators introduce effect sources.
- **Derived node** — `map`, `map2`, `combine`. Holds a retained Roc transform
  closure plus its input node ids. The host recomputes it when an input changes.
- **Reducer** — a pure state transition closure attached to a source through a
  `Node.Msg`. Unit reducers are `a -> a`; payload reducers are typed wrappers
  such as `(a, Str -> a)`, `(a, Bool -> a)`, or `(a, KeyPayload -> a)`. The host
  retains the erased reducer and calls it when the bound event fires.
- **Scope** — a host-owned region that owns minted node ids and retained
  closures: the root, each conditional branch, and each list row are scopes.
  Disposing a scope drops its refcounts and detaches its DOM.
- **Elem** — a pure description of UI structure that references signals for
  dynamic text/attrs and references reducers for event handlers. Element nodes
  carry a tag string, attrs, and children; user-controlled copy stays in text
  nodes (`Html.text` / `Html.text_s`), not raw HTML.
- **Selector** — a host-owned keyed node derived from a `Signal(Str)`. Each
  member `Signal.select(keys, k)` is a `Signal(Bool)` that is true while the
  selected string equals `k`. When the key changes the host dirties exactly the two
  members whose membership changed; no member closure runs for the rest. This
  is how "which row is selected" stays O(1) per change at any list size.
- **Component** — a typed, reusable unit of UI with inputs, children, and its
  own scope for local state, effects, and cleanup. A component is an ordinary
  Roc function that returns `Elem`; `Ui.component` gives it the scope.
  Components are published from ordinary Roc packages.
- **Cmd** — typed, outbound effect requests produced by lifecycle or
  signal-change sinks: start a task, navigate history, set the document title,
  write or remove storage, send a message to an attached widget. Task results
  re-enter the graph through the same propagation queue as a click.
- **Sub(a)** — a typed, inbound, long-lived source declared by structure and
  owned by the scope that declares it: timers, browser environment values
  (location, visibility, online, storage), and widget events. Subscriptions
  are diffed by stable descriptor identity, started when their scope is
  created, and stopped when it is disposed. Inbound payloads use the shared
  boundary schema vocabulary, and any retained source value or callback uses
  the same capability-owned `HostValue` model as events and tasks.
- **Effect registry** — the typed table, built at ingestion from the
  descriptor tree, that maps each declared `Cmd` kind and `Sub` kind to its
  host route and to the capability that decodes its result. Routing is by
  dense registry id, never by a string convention.

## Identity: Construction-Site Within Explicit Scopes

There are no author-written node ids or event ids. Identity is assigned by the
host during graph ingestion; keyed rows use app-provided stable key material.

Signal alias identity is the address of the boxed callable the signal already
needs for evaluation: initializers identify constants, state, tasks, and
intervals; transforms identify derived signals; browser sources use their
`from_payload` transforms. The descriptor carries this pointer as both the
record's identity and its evaluator, and ingestion asserts that they agree. Cloned signal descriptors therefore share a record, while two
separately constructed signals get distinct callable allocations even when they
use the same specialization. A fused keyed-row selector instead has composite
identity `(site callable, row handle)`: one site owns the typed reader,
selected/unselected initializers, and output capability, while every row remains
an ordinary independently cached graph record registered under its exact key.
Persistent and transaction-local composite indexes are separate from the
callable-only indexes used by other signals and effects. Callable addresses are lookup keys only; the host
still owns separate dense node, active-graph, task-request, interval, and DOM ids.

- Within a scope, node identity is **construction order** (the order the app
  built the nodes). The app build is pure and deterministic, so this order is
  stable across rebuilds of the same scope.
- **Scopes contain positional shifting.** Because components, conditional
  branches, switch cases, and list rows are first-class scopes, adding or
  removing UI inside one scope does not shift identities in sibling scopes. This is the new failure mode we design
  around: "where you built it is your identity," so the seams that can shift
  (branches, lists) are explicit scope boundaries.
- **Dynamic lists use stable UTF-8 key material, not position.** `Ui.each` takes
  a `Signal(Rows(item))`; the immutable `Rows` value owns the one
  `item -> Str` key function used for every generation. Identity is the exact
  UTF-8 byte sequence returned when an item enters or changes: no normalization,
  case folding, locale transform, lossy decode, or hash-only equality is
  permitted. `Rows` caches that key beside the item and maintains an exact-key
  index; the host owns copied key bytes for each live row and hashes them
  privately for its site lookup table. Collisions and duplicate-key checks
  compare complete bytes. A row's identity is that key, so per-row local state
  survives reorder/insert/delete. Duplicate byte-identical keys are an ordinary
  `Rows.Error` while constructing or editing a value and a contract error if an
  adapter violates the authenticated transition ABI; they are never aliases.
  Row handles, sink tokens, generations, and all host-minted dense identities
  are nonzero and nonwrapping: an exhausted generation retires its slot instead
  of aliasing an earlier lifetime, and an exhausted dense id space is a resource
  error rather than permission to reuse a live or stale identity.

- **Branches are built when selected, not at construction.** `Ui.when` and
  `Ui.switch` retain their branch builders as structure closures; the host
  invokes the builder for a branch when that branch becomes live and disposes
  the branch scope when it stops being live. Because an unselected branch is
  never built, a structure may refer to itself through a branch and terminate:
  recursive UI (a tree of query groups, nested markdown blocks) is expressed
  directly, never encoded into a list key.
- **A component is a scope.** `Ui.component` mints a scope for the component
  body, so the body's `Ui.state`, subscriptions, and cleanup are owned by the
  component and construction order inside it is independent of the caller.
  Two uses of the same component at different sites are different scopes with
  different identities; identity still comes from the construction site, not
  from the component's name.

This replaces string-collision/rename hazards with explicit, typed structure.

## Confined Erasure: No NodeValue, No Decode Crash

The host's node table is heterogeneous, so values cross the boundary as opaque
payloads. Erasure is confined to **one capability per retained edge**, pinned to
that edge's monomorphized types:

- For each `map`/`map2`/`combine`/`state`/source/sink edge, platform Roc builds a
  concrete capability at the call site. Static dispatch resolves the value's
  required operations (`is_eq`, key hashing, sink reads, and similar
  edge-specific functions), and monomorphization specializes the capability and
  any capability-owned extension record for that edge's concrete `a`.
- The host **never chooses** a decoder, destructor, comparator, or reader. It
  stores a boxed, opaque Roc value and invokes the capability that owns that edge.
  There is no second, independently typed read site, so a mismatch is a routing
  assertion failure in debug builds, not a runtime decode crash.

Hot-path values are stored as **boxed typed Roc values the host never
inspects**. Equality uses the capability's typed `eq`; byte serialization is
reserved for persistence and the wire, never forced on every event. We do not
`memcmp` encoded bytes for equality (fragile for floats/maps), and the host never
reconstructs type semantics from bytes.

This opaque carrier must be produced at a real typed edge boundary. It is not a
generic `Box({})` field in the descriptor tree: Roc keeps `Box(a)` typed, so a
generic `Opaque(a)` value cannot be placed directly into heterogeneous `Elem`
payloads. The platform boundary produces a `HostValue` cell at the monomorphized
call site and carries the capability that owns that cell.

There is no untyped value representation crossing the boundary. The public API
is a few polymorphic functions (below); monomorphization generates concrete code
for each instantiation, so there is no hand-written family of type-specialized
combinators.

### Where the invariant actually lives, and how we check it

Confined erasure moves the type-mismatch hazard, it does not delete it. Roc's
type system guarantees that *each* thunk is internally type-correct. It does
**not** guarantee that the host hands a given opaque payload to the *right*
thunk: that correctness is a property of the host's wiring matching the
descriptor that produced the thunks. A wiring bug — delivering the box from edge
X to the thunk that owns edge Y — is therefore not a clean Roc error but
undefined behavior in the thunk.

Two rules keep this invariant honest:

1. **The routing is consumed, never reconstructed.** The host builds its
   `event_id -> source`, edge, and sink tables from explicit callable identities in the
   descriptor. It never re-derives which thunk owns which value by guessing from
   structure or bytes.
2. **Capability ownership assertions.** Every opaque `HostValue` cell carries
   the app-compiled capability that owns it. Public get/take operations must
   present the same capability, and internal split/take operations are accepted
   only while the host is executing an app-compiled callable under an active
   frame containing that owning capability. If a value crosses to the wrong edge,
   the host reports a capability mismatch instead of trying to recover. This is
   part of the design, not an optional extra.

### The capability: bundled ownership operations per retained value

A thunk that *reads* an erased value is not enough. The host does not only read
these values — it **owns their lifecycle**. After `roc_ui_init` the host owns the
mutable runtime graph: state cells, source caches, derived-signal caches, keyed
collection generations, pending task payloads, and sink values. Those cells are
replaced during propagation, pruned when unchanged, cloned for non-consuming
reads, and destroyed when a scope is disposed or the app unmounts. At each of
those moments the host is the only code that knows a particular value is now
dead, so the host is the code that must release it.

The prebuilt host cannot release an app value by inspecting it. The host can own
an opaque cell, but `a` comes from the app, not the platform. When a retained
`Box(a)` reaches its final release, the payload's nested refcounted fields — a
`Str` backing, a `List`, a record of lists, a tag union carrying a heap string —
must also be released, and that requires the concrete monomorphized layout the
prebuilt host was compiled without.

Every retained `HostValue` is therefore paired with a **capability**: one bundled
record of app-compiled, monomorphized operations for that value's exact type,
produced at the same typed edge that produced the value. The capability is the
typed instruction manual attached to the opaque cell. Conceptually:

```roc
# Produced at the monomorphized edge, stored beside the opaque cell.
CapabilityHandle := {
    clone : Box((HostValue -> HostValue)),        # split-and-store clone
    eq    : Box((HostValue, HostValue -> Bool)),  # value pruning
    drop  : Box((HostValue -> {})),               # release, incl. nested fields
}
```

- **Clone, equality, and drop are the universal trio** every retained value
  needs, because every retained value can be copied for a read, compared for
  pruning, and released on disposal. They are bundled into one object so a value
  and the operations that own it cannot drift apart.
- **Typed split is private to the app-compiled capability operations.** The
  platform Roc wrapper for `Capability(a)` builds a typed
  `split : Box(a) -> { keep : Box(a), out : Box(a) }` closure and captures it in
  the generated `clone`, `eq`, and `drop` callables. The heterogeneous descriptor
  graph stores only the erased handle above, not a parameterized
  `CapabilityHandle(a)`.
- **Reads, reducers, and row operations are edge-specific extensions**, not part
  of the universal trio. A signal-backed text edge owns a
  `{ capability, read : HostValue -> Str }` record; a `Ui.when` condition owns a
  `{ capability, read : HostValue -> Bool }` record; a task request read and an
  event reducer carry their operation the same way; `Ui.each` owns one ops
  record containing its `Rows`/item capabilities plus `describe`,
  `copy_snapshot`, `copy_delta`, `compare_slots`, `clone_item`, and `row`.
  These records are carried by the edge that needs them, never invented by the
  host.
- **The capability is app-compiled, not host-authored.** The prebuilt host sees
  only the platform ABI; `a` is made concrete by the *application* (`Signal(a)`,
  `Model`, a row item type). The capability's closures are emitted by
  monomorphization when the app is built and handed to the host as ordinary
  `RocErasedCallable` values. The host stores and invokes them; it never inspects
  the layout they encapsulate.

### Immutable `Rows` generations and preallocated sinks

`Rows(item)` is an opaque, ordinary Roc value: it can live in state, task
results, records, and derived signals. It owns `key_of`, cached exact keys, and
stable generational slot ids, and publishes either a full snapshot or a
normalized delta from its immediate parent. `Rows.is_eq` compares a private
boxed-callable generation identity in O(1); cloning a value preserves identity,
while every content-changing operation creates a fresh identity. A hosted
callable-identity hook is the only code allowed to compare those tokens. The ABI
proof must establish uniqueness in optimized native and Wasm builds and balanced
ARC ownership; no pointer/content approximation may replace that proof.

The persistent representation is a 32-way order tree over stable slot ids, a
chunked generational slot store containing items and cached keys, and an
exact-key persistent hash index. Slot ids pack a nonzero 32-bit index and a
32-bit generation. A generation never wraps: a saturated slot retires, and
exhausting the available slot space returns `Rows.SlotExhausted`. A value retains
only its immediate parent token and transition, never an unbounded history.

`Rows.apply` validates edits sequentially. `MoveRange.to` is interpreted after
source removal. Equal same-key sets normalize away; an unequal same-key set
keeps its slot, while a key-changing set is remove-plus-insert and therefore
resets row-local state. Removing and reinserting the same key within one
unpublished batch preserves that slot when the final value still contains it.
Invalid indexes/ranges, missing keys, and duplicate exact keys return structured
`Rows.Error` values without publishing a partial generation. `replace_all`
publishes an explicit snapshot and reuses stable slots for surviving keys.

`Ui.each` does not materialize `List(HostValue)`, `List(Str)`, or returned
comparison/edit batches. Its signal value is one capability-owned `Rows(item)`
generation retained as an opaque `HostValue`. The app-compiled ops record is the
only code allowed to interpret it:

```text
describe       : HostValue, metadata_sink -> void
copy_snapshot  : HostValue, slot_and_key_sink -> void
copy_delta     : HostValue, edit_and_key_sink -> void
compare_slots  : HostValue, HostValue, slot_pairs, bool_sink -> void
clone_item     : HostValue, slot_id -> HostValue
row            : Str, row_handle -> Elem
```

Every callback receives an independently owned clone of each collection-owner
argument. A generation retained by the site is never passed as an untracked
borrow; consuming or rejecting callback input cannot invalidate it. The callback
consumes those owner clones exactly once. The host reserves exact bounded storage
from `describe`, then activates transaction-scoped sink tokens. Snapshot and
delta callbacks write directly into those sinks. Sinks consume owned strings and
primitive batches and validate token, count, order, byte bounds, slot validity,
transition kind, parent identity, and capability ownership. Tokens are
unforgeable within the instance, nonzero, nonwrapping, valid only for their
active callback, and invalidated on success or abort. Missing, stale, duplicate,
out-of-range, or incomplete pushes are contract errors; no persistent returned
Roc batch exists.

A matching immediate parent token selects the sparse delta path. A valid but
nonmatching token deterministically selects exact full-snapshot reconciliation
and increments `rows_snapshot_batches`; it is not an error or heuristic. A null,
malformed, or falsely claimed delta token is a contract error. After a stale
sibling takes the snapshot path, its next direct edit again has a matching parent
and resumes sparse processing.

The old and candidate `Rows` values remain independently retained through
comparison. Their item capabilities must match. The host clones an item through
`clone_item` only when a new row must be materialized or a surviving row's
ordinary graph source receives an unequal value. Unchanged and removed rows do
not box every item. A row builder runs only for a newly live key. `Ui.Row.map` is
normal `Signal.map` over the stable row source, so row updates participate in
dependency ordering and equality pruning rather than a parallel observer path.

Reconciliation is a candidate overlay. Key bytes, duplicate detection, slot
comparisons, row-handle reservations, item clones, structural plans, and command
reservations are provisional until validation and all fallible host allocation
succeeds. Commit swaps the generation, publishes row-source updates and local
structural splices, and exposes one complete command batch without allocation.
Abort releases candidate ownership, provisional items, keys, handles, and sink
state and leaves the committed generation and DOM untouched. The old generation
is released only after successful publication.

Generation ownership is site-scoped. At most the committed generation plus a
transaction's candidate generation are retained for one `Ui.each` site, apart
from independently owned item clones installed in live row-source nodes.
Disposal releases the committed generation, adapter callables and capabilities,
row sources, keys, handles, and subtrees deterministically. There is no general
descriptor owner or cross-site/global key, string, item, or callable pool.

**The split law.** `get`/`get_tagged` is *split-and-replace clone, never a
borrow*. The capability's app-compiled clone operation uses its private typed
split closure to turn the stored owned `Box(a)` into two independently owned
boxes: `keep` is written back into the source cell and `out` is stored as the
clone. A public get then consumes the clone. Dropping either box must not
invalidate the other, and any nested refcounted field (`Str`, `List`, record,
tag union, boxed closure) must end up independently owned in both. The host
relies on this law but never enforces it by inspecting bytes; correctness is the
capability's responsibility, expressed in typed Roc and lowered by the backend.

**Boundary discipline.** The host never walks a payload, never increments a
nested refcount, and never identifies a value by pointer shape. Every ownership
action — clone, compare, release — is a capability call. Typed aliasing
operations that share backing must retain that backing in typed Roc/compiler
lowering, not in the host. The active capability frame above is the host-side
guardrail: the host asserts that a value is only ever handed to the capability
that produced or owns its edge, which is what makes a routing bug a caught
contract violation rather than undefined behavior.

This is dictionary passing made concrete: a retained cell is morally an
existential `exists a. { value : Box(a), cap : clone/eq/drop closures for a }`.
The host holds the package without knowing `a`; Roc owns all type knowledge; the
capability bridges the two.

## App-Facing API

The app sees `Signal(a)`, `Ui.Row(a)` with exact UTF-8 identity, `Elem`,
task/effect helpers, and a small set of polymorphic functions. It never sees
host ids, host-private key hashes, `NodeValue`, or lifecycle tokens. The API is
identical regardless of which host runs the app — apps are written once and run
under both the native spec runner and the browser.
Everything that crosses to JavaScript — `Cmd` out, `Sub(a)` in, and widget
attachments — is one declared boundary (see *One door to JavaScript*). There
is no second payload format, no public id route table, and no browser-only
state channel.

### Module surface

Signatures use Roc syntax: parenthesized type application (`Signal(a)`,
`List(Elem)`), and `where [...]` static-dispatch constraints naming the methods
a type variable must provide. There is no `implements`/ability syntax; a
constraint such as `a.is_eq : a, a -> Bool` says "the concrete type bound to `a`
must define an `is_eq` method of that signature," which monomorphization
resolves and specializes.

```roc
# Opaque to the app:
Signal(a)
Rows(item)
Elem
Task(a, err)
TaskStatus(a, err)
Cmd              # produced and consumed by helpers; not a public id surface
Cleanup          # produced and consumed by helpers; not a public id surface

# Signal construction and combination
Signal.const : a -> Signal(a)
    where [a.is_eq : a, a -> Bool]
Signal.map : Signal(a), (a -> b) -> Signal(b)
    where [b.is_eq : b, b -> Bool]
Signal.map2 : Signal(a), Signal(b), (a, b -> c) -> Signal(c)
    where [c.is_eq : c, c -> Bool]
Signal.combine : List(Signal(a)) -> Signal(List(a))
    where [a.is_eq : a, a -> Bool]
Signal.combine_map : List(Signal(a)), (List(a) -> b) -> Signal(b)
    where [b.is_eq : b, b -> Bool]
Signal.select : Signal(Str), Str -> Signal(Bool)   # O(1) members dirtied per key change
Signal.keyed : Signal(Str), value, value -> Signal.Keyed(value)
    where [value.is_eq : value, value -> Bool]
Ui.Row.select : Ui.Row(item), Signal.Keyed(value) -> Signal(value)
# Named multi-signal composition should use Roc record-builder syntax:
# { first: first_signal, last: last_signal, active: active_signal }.Signal

# Async / effects as sources (same propagation path as user events)
Signal.fake_task : Str, (Str -> a), (Str -> err) -> Task(a, err)
Signal.from_task : Task(a, err) -> Signal([Loading, Done(a), Failed(err)])
Signal.fold_task : Task(a, err), b, (a -> b), (err -> b) -> Signal(b)
Signal.start_str : Task(a, err), Str -> Cmd
Signal.cleanup : Str -> Cleanup
Signal.interval : U64 -> Signal(U64)  # period ms -> tick count
Ui.on_change : Signal(a), (a -> Cmd) -> Elem  # sink: fires a Cmd when value changes
Ui.on_change_initial : Signal(a), (a -> Cmd) -> Elem  # fires for first mounted value, then changes
Ui.on_mount : (() -> Cmd) -> Elem
Ui.on_cleanup : Cleanup -> Elem               # runs at scope disposal

# Structure
Html.div : List(Html.Attr), List(Elem) -> Elem
Html.form : List(Html.Attr), List(Elem) -> Elem
Html.form_label : Str, List(Html.Attr), List(Elem) -> Elem
Html.link : Str, List(Html.Attr) -> Elem
Html.section : Str, List(Html.Attr), List(Elem) -> Elem
Html.heading : Str -> Elem
Html.paragraph : Str -> Elem
Html.paragraph_s : Signal(Str) -> Elem
Html.pre_s_c : Signal(Str), Str -> Elem
Html.button : Str, Msg -> Elem
Html.action_button : Signal(Str), Signal(Bool), Msg -> Elem
Html.text_input : Str, Signal(Str), Msg -> Elem
Html.number_input : Str, Signal(Str), Msg -> Elem
Html.textarea : Str, Signal(Str), Msg -> Elem
Html.select : Str, Signal(Str), List(Elem), Msg -> Elem
Html.option : Str, Str -> Elem
Html.option_attrs : Str, Str, List(Attr) -> Elem
Html.radio : Str, Str, Str, Signal(Str), Msg -> Elem
Html.checkbox : Str, Signal(Bool), Msg -> Elem
Html.text : Str -> Elem            # static text
Html.text_s : Signal(Str) -> Elem  # signal-backed text (a sink)
# Many element helpers also expose `_c`, `_sc`, `_s`, and `_attrs` variants for
# static class, signal-backed class/text, and extra attrs, including focused
# helpers like `button_s_c` and `action_button_c`. These are sugar over the same
# descriptor vocabulary.

# Attributes (signal-backed where dynamic)
Html.class_attr : Str -> Attr
Html.class_attr_s : Signal(Str) -> Attr
Html.test_id : Str -> Attr
Html.attr : Str, Str -> Attr
Html.attr_s : Str, Signal(Str) -> Attr
Html.attr_maybe_s : Str, Signal([None, Some(Str)]) -> Attr
Html.bool_attr : Str -> Attr
Html.bool_attr_if : Str, Bool -> List(Attr)
Html.bool_attr_s : Str, Signal(Bool) -> Attr
Html.required : Attr
Html.readonly : Attr
Html.aria_label : Str -> Attr
Html.aria_describedby : Str -> Attr
Html.aria_invalid_s : Signal(Bool) -> Attr
Html.aria_activedescendant_s : Signal([None, Some(Str)]) -> Attr
Html.EventPolicy : Node.EventPolicy
Html.EventDelivery : Node.EventDelivery
Html.event_policy_none : EventPolicy
Html.event_policy_prevent_default : EventPolicy
Html.event_policy_stop_propagation : EventPolicy
Html.event_policy_stop_immediate : EventPolicy
Html.event_delivery_auto : EventDelivery
Html.event_delivery_native : EventDelivery
Html.on_event : Str, EventPolicy, Msg -> Attr
Html.on_custom : Str, Msg -> Attr
Html.on_event_delivery : Str, EventPolicy, EventDelivery, Msg -> Attr
Html.on_submit_prevent_default : Msg -> Attr
Html.on_pointer_down : Msg -> Attr
Html.on_pointer_up : Msg -> Attr
Html.on_pointer_enter : Msg -> Attr
Html.on_pointer_leave : Msg -> Attr
Html.on_key_down : Msg -> Attr
Html.on_focus : Msg -> Attr
Html.on_blur : Msg -> Attr
Html.on_change : Msg -> Attr
Html.on_composition_start : Msg -> Attr
Html.on_composition_end : Msg -> Attr

# Package-aligned HTTP tasks
HttpError := [Network(Str), Timeout, Canceled, Unsupported(Str), ResponseMaterialization(Str)]
Request        # `roc-lang/http` request value
Response       # `roc-lang/http` response value
Method         # `roc-lang/http` method value
Timeout        # `roc-lang/http` timeout value
Http.method_get : Method
Http.method_post : Method
Http.method_put : Method
Http.method_delete : Method
Http.method_patch : Method
Http.method_unknown : Str -> Method
Http.request_task : Str -> Task(Response, HttpError)
Http.start : Task(Response, HttpError), Request -> Cmd
Http.get : Task(Response, HttpError), Str -> Cmd
Http.get_text_task : Str -> Task(Str, Str)
Http.get_text : Task(Str, Str), Str -> Cmd
Http.error_text : HttpError -> Str
Http.request_from_method : Method -> Request
Http.request_method : Request -> Method
Http.request_method_str : Request -> Str
Http.request_headers : Request -> List((Str, Str))
Http.request_body : Request -> List(U8)
Http.request_uri : Request -> Str
Http.request_timeout : Request -> Timeout
Http.with_method : Request, Method -> Request
Http.with_headers : Request, List((Str, Str)) -> Request
Http.add_header : Request, Str, Str -> Request
Http.with_uri : Request, Str -> Request
Http.with_body : Request, List(U8) -> Request
Http.with_timeout_ms : Request, U64 -> Request
Http.with_no_timeout : Request -> Request
Http.response_from_status : U16 -> Response
Http.response_status : Response -> U16
Http.response_headers : Response -> List((Str, Str))
Http.response_body : Response -> List(U8)
Http.response_with_status : Response, U16 -> Response
Http.response_with_headers : Response, List((Str, Str)) -> Response
Http.response_add_header : Response, Str, Str -> Response
Http.response_with_body : Response, List(U8) -> Response

# Browser environment
Browser.Location := { path : Str, query : Str, hash : Str }
Browser.Visibility := [Visible, Hidden]
Browser.StorageText := [StorageMissing, StorageValue(Str), StorageUnavailable(Str)]
Browser.location : () -> Signal(Browser.Location)
Browser.entropy_seed : () -> Signal(U32)
Browser.visibility : () -> Signal(Browser.Visibility)
Browser.online : () -> Signal(Bool)
Browser.local_storage_text : Str -> Signal(Browser.StorageText)
Browser.session_storage_text : Str -> Signal(Browser.StorageText)
Browser.push_state : Browser.Location -> Cmd
Browser.replace_state : Browser.Location -> Cmd
Browser.set_title : Str -> Cmd
Browser.set_local_storage_text : Str, Str -> Cmd
Browser.set_session_storage_text : Str, Str -> Cmd
Browser.remove_local_storage : Str -> Cmd
Browser.remove_session_storage : Str -> Cmd

# Dynamic structure (explicit scopes)
Ui.state : a, (State(a) -> Elem) -> Elem
    where [a.is_eq : a, a -> Bool]
State.signal : State(a) -> Signal(a)
State.on_unit : State(a), (a -> a) -> Msg
State.on_str : State(a), (a, Str -> a) -> Msg
State.on_bool : State(a), (a, Bool -> a) -> Msg
State.on_detail : State(a), (a, Str -> a) -> Msg
Ui.KeyPayload : { key : Str, shift_key : Bool }
State.on_key : State(a), (a, Ui.KeyPayload -> a) -> Msg
Ui.when : Signal(Bool), (() -> Elem), (() -> Elem) -> Elem   # builders retained, run when selected
Ui.switch : Signal(case), (case -> Elem) -> Elem            # one scope per live case value
    where [case.is_eq : case, case -> Bool]
Ui.Row(a)
Ui.Row.key : Ui.Row(a) -> Str
Ui.Row.signal : Ui.Row(a) -> Signal(a)
Ui.Row.map : Ui.Row(a), (a -> value) -> Signal(value)
    where [value.is_eq : value, value -> Bool]

Rows.Error := [
    DuplicateKey(Str),
    IndexOutOfBounds({ index : U64, len : U64 }),
    KeyNotFound(Str),
    RangeOutOfBounds({ at : U64, count : U64, len : U64 }),
    SlotExhausted,
]
Rows.Before := [End, Key(Str)]
Rows.Edit(item) := [
    Append(List(item)),
    Clear,
    InsertAt({ at : U64, items : List(item) }),
    InsertBefore({ before : Str, items : List(item) }),
    MoveKeyBefore({ key : Str, before : Rows.Before }),
    MoveRange({ from : U64, count : U64, to : U64 }),
    RemoveKey(Str),
    RemoveRange({ at : U64, count : U64 }),
    SetAt({ at : U64, item : item }),
    SetKey({ key : Str, item : item }),
]
Rows.empty : (item -> Str) -> Rows(item)
Rows.from_list : List(item), (item -> Str) -> Try(Rows(item), Rows.Error)
Rows.replace_all : Rows(item), List(item) -> Try(Rows(item), Rows.Error)
Rows.apply : Rows(item), List(Rows.Edit(item)) -> Try(Rows(item), Rows.Error)
    where [item.is_eq : item, item -> Bool]
Rows.len : Rows(item) -> U64
Rows.get : Rows(item), U64 -> Try(item, Rows.Error)
Rows.get_key : Rows(item), Str -> Try(item, Rows.Error)
Rows.iter : Rows(item) -> Iter(item)
Rows.to_list : Rows(item) -> List(item)
Rows.content_is_eq : Rows(item), Rows(item) -> Bool
    where [item.is_eq : item, item -> Bool]
Rows.is_eq : Rows(item), Rows(item) -> Bool
Ui.each : Signal(Rows(item)), (Ui.Row(item) -> Elem) -> Elem

# Components (a scope with inputs and children)
Ui.component : (() -> Elem) -> Elem

# Subscriptions (inbound, scope-owned) and widgets (the JavaScript door)
Sub(a)                                       # opaque declared source descriptor
Ui.subscribe : Sub(a), a -> Signal(a)        # declare it in this scope; initial value until first message
Ui.widget : Str, List(Html.Attr), List(Elem) -> Elem   # attach a registered widget to this element
Ui.widget_input_s : Str, Signal(a) -> Html.Attr        # typed message to the widget on change
    where [a.to_boundary : a -> Node.BoundaryValue]
Ui.widget_event : Str, Msg -> Html.Attr                # typed event from the widget into a reducer
```

`Ui.component` is a scope, not a syntax. A component is an ordinary Roc
function whose arguments are its inputs — static values, `Signal(a)` values,
`Msg` callbacks the parent supplies, and `List(Elem)` children — and whose body
is wrapped in `Ui.component`. The wrapper mints the scope that owns the body's
`Ui.state`, subscriptions, and cleanup, so a component's local state is
construction-site-stable within the component and invisible to its caller.
Children are ordinary `Elem` values built in the parent's scope and placed by
the component, so their identity belongs to the parent. Because a component is
a function over public types only, any Roc package can export one; the
platform's descriptor plumbing is not part of a component's interface.

`Ui.when` and `Ui.switch` are the same mechanism at two arities: a scope
selected by a value, whose builder is retained and run only when its case is
live. `Ui.when` is the `Bool` special case; `Ui.switch` selects by any
`is_eq` value, rebuilding the scope when the case value changes and reusing it
while the value is unchanged. Choosing structure by a tag, an enum, or a route
therefore never goes through a `Str` key.

`Ui.each` hands the builder an opaque `Ui.Row(item)`, deliberately not an item
snapshot. `row.key()` returns the stable UTF-8 identity, `row.signal()` returns
the one ordinary graph source for the current item, and `row.map(project)` is
ordinary equality-pruned `Signal.map` over that source. It is not a second row
reactivity mechanism. Structure inside a row that depends on the item is chosen
with `Ui.switch` or `Ui.when` over a row projection.

The form helpers above are sugar over the same text/bool fields and event
payload descriptors: text input, number input, textarea, and single-value select
use the target-value path; checkbox uses target-checked; radio derives checked
from a string-valued selected signal and dispatches the option value. They do
not introduce separate browser-state channels.

Rich content is ordinary `Elem` structure. Apps or packages may parse markdown,
prose blocks, or CMS data into `Elem.Element({ tag, attrs, children })` nodes,
including headings, lists, blockquotes, inline code, emphasis, and links, while
placing user-controlled text only in `Html.text` or `Html.text_s` leaves. The
platform intentionally exposes no raw HTML, `innerHTML`, or sanitizer surface;
link-scheme allowlists, markdown parsing, and other content policy stay in
app/package code unless repeated maintained apps prove a smaller shared helper
is needed.

HTTP helpers are wrappers over the pinned `roc-lang/http` request/response
values plus Signals-owned transport errors. The text helpers decode successful
response bodies as UTF-8. Body codecs are not platform surface: apps use the
builtin `Json` plus app-local mappers. Request policy beyond the fields the
request envelope carries is the browser's `fetch` default; the platform does
not grow a policy surface it cannot also honour on the native host.

`Signal.task_source` is platform-internal plumbing beneath `Signal.fake_task`
and `Http`. Task and subscription kinds are registered in the typed effect
registry at ingestion; there is no string-named task convention and no generic
public effect registry for apps to reach into.

`Signal.clone_expr`, `Signal.to_expr`, and `Signal.from_expr` are
platform-private descriptor plumbing shared by `Html` and `Ui`. They are not
app-facing; an app or package composes signals and components through the
public functions only, and no public signal ids, descriptor inspection, or
host-owned construction helpers exist.

`Msg` here is the unit of host-to-Roc dispatch: a bound reducer plus an optional
payload. `Html.text_input("Name", name_signal, name_state.on_str(update_name))`
means "when this input fires, route the target-value payload through
`update_name` and apply the bound reducer." The app never names an event id; the
host mints and routes them.

### Boundary payloads and event bindings

`Node.Msg` is the app-facing reducer descriptor. It carries:

- a `BinderRef` naming the state/source binder to update;
- an `EventExtractionPlan` byte descriptor naming what the host should extract
  from the event;
- a capability-owned reducer handle that can decode the resulting `HostValue`
  payload and produce the next typed state.

The shared boundary schema vocabulary is intentionally small:

```text
1 = unit
2 = text
3 = bool
4 = record
```

DOM event extraction reuses those schema tags, then adds DOM-specific producer
bytes after scalar nodes: source (`event`, `target`, `currentTarget`) and leaf
(`key`, `value`, `checked`, `shiftKey`, `detail`). Records are non-empty, flat,
UTF-8-named records of scalar leaves with no duplicate field names. Scalar
payloads dispatch as unit/text/bool containers; record payloads dispatch as
bytes, and app-compiled Roc decoders such as `State.on_key` construct the typed
record. Hosts never decode Roc records or infer a payload from DOM shape.

`EventExtractionPlan` is a compact Roc-side byte value naming one supported
plan: unit, target value, target checked, event detail, or the
`{ key, shift_key }` keyboard record. The host expands those into
`BoundaryPayloadDescriptor` data for render-cache comparison and, on the browser
wire, emits the extraction descriptor bytes so JS can validate and execute the
plan. Unsupported source/leaf pairs, nested records, duplicate fields, trailing
bytes, or mismatched payload containers are contract errors.

Every event binding has one canonical internal shape:

```text
EventBinding := {
  event_id,
  policy,              # preventDefault, stopPropagation, stopImmediate,
                       # capture, passive, once, self, trusted
  delivery,            # requested/effective/reason
  payload_descriptor,
}
```

`EventDelivery` is derived by the host before render-cache storage. The public
request is `auto` or `native`. The effective delivery is `native` whenever the
policy requires a per-element listener (capture, stop-propagation,
prevent-default, once, passive, self filter, pointer drag) or the app requested
it, and the wire carries the reason; `delegated` is the effective delivery only
when the host has chosen it for a policy-free binding. Delivery is a host
decision carried on the wire, never a JS-side inference.

Fixed event opcodes are compression for canonical fixed bindings only: a fixed
binding may use the compact opcode when policy is empty and its payload
descriptor matches the fixed event kind. Otherwise fixed events and all named
events lower through the dynamic `BindEvent` record carrying the same canonical
binding data. The browser decodes fixed and dynamic event records into the same
listener shape.

Native specs model the browser default actions the platform specifies.
`real_click` dispatches through propagation before applying supported
defaults: app-managed submit for submit buttons, app-managed reset for reset
buttons, checkbox checked changes, and radio target-value changes. `key_down`
models Enter submit from text-like inputs. App-managed submit/reset bindings
must be unit payloads with static prevent-default policy.

### One door to JavaScript

Three surfaces, one boundary. Each is declared by structure, owned by a scope,
typed through the boundary schema vocabulary, and routed by a dense id from the
effect registry:

- **`Cmd` (outbound).** A typed request the host serializes into the command
  stream. Tasks carry a request id for settlement and cancellation; widget
  messages carry the target element id and a boundary value.
- **`Sub(a)` (inbound).** A typed long-lived source. `Ui.subscribe(sub, initial)`
  declares it in the current scope and yields a `Signal(a)`; the host starts
  the bridge when the scope is created and stops it when the scope is
  disposed. Timers and the `Browser.*` sources are `Sub` instances.
- **Widgets (third-party integration).** `Ui.widget(name, attrs, children)`
  attaches a widget registered under `name` in the JS runtime to an element.
  The widget receives typed input via `Ui.widget_input_s` (each change lowers
  to a command carrying a boundary value) and raises events through
  `Ui.widget_event`, which is an ordinary event binding: same event id table,
  same extraction plan, same reducer dispatch. The widget's DOM subtree is
  opaque to the engine; the engine owns the host element and detaches the
  widget when the scope is disposed.

The registry of widget names is JS-side configuration supplied at mount, and
an unknown name is a mount-time contract error, not a runtime fallback. No
surface exposes a global, a raw DOM node, or a second payload format.

### Example: counter

```roc
counter : Elem
counter =
    Ui.state(0i64, |count_state| {
        count = count_state.signal()
        dec = count_state.on_unit(|n| n - 1)
        inc = count_state.on_unit(|n| n + 1)

        Html.div(
            [],
            [
                Html.button("-", dec),
                Html.text_s(Signal.map(count, |n| n.to_str())),
                Html.button("+", inc),
            ],
        )
    })
```

### Example: derived value

```roc
full_name : Signal(Str), Signal(Str) -> Signal(Str)
full_name = |first, last| {
    parts = { first: first, last: last }.Signal
    Signal.map(parts, |value| "${value.first} ${value.last}")
}
```

### Example: text input with retained state

```roc
name_field : Elem
name_field =
    Ui.state("", |text_state| {
        text = text_state.signal()
        Html.text_input(
            "Name",
            text,
            text_state.on_str(|_current, value| value),
        )
    })
```

`text` survives across events because the `Ui.state` binder is an
identity-bearing construction site. The host holds it by its minted id, not by a
string and not by re-derived tree position.

### Example: keyed list with per-row local state

```roc
todo_list : Signal(Rows(Todo)) -> Elem
todo_list = |todos|
    Html.div(
        [],
        [
            Ui.each(
                todos,
                |row| {
                    Ui.state(Bool.false, |editing_state| {
                        editing = editing_state.signal()
                        Html.div(
                            [],
                            [
                                Html.text_s(row.map(|t| t.title)),
                                Html.button("Toggle edit", editing_state.on_unit(|e| !e)),
                                Html.text_s(Signal.map(editing, |e| if e { "done" } else { "edit" })),
                            ],
                        )
                    })
                },
            ),
        ],
    )
```

`editing` is a per-row source inside the row scope. It survives reorder/filter
because the row scope is keyed by the exact UTF-8 bytes returned by `row.key()`,
not by the index.

### Example: a component with inputs, children, and local state

```roc
# In any package: a disclosure panel whose open/closed state is its own.
panel : Signal(Str), Msg, List(Elem) -> Elem
panel = |title, on_close, children|
    Ui.component(|| {
        Ui.state(Bool.true, |open_state| {
            open = open_state.signal()
            Html.section("panel", [], [
                Html.action_button(title, Signal.const(Bool.true), open_state.on_unit(|o| !o)),
                Html.button("Close", on_close),
                Ui.when(open, || Html.div([], children), || Html.text("")),
            ])
        })
    })
```

`open` belongs to the panel's scope; `title`, `on_close`, and `children` belong
to the caller. Two `panel` uses at two sites are two scopes.

### Example: selection in a large list

```roc
row_view : Signal(Str), Str, Signal(Item) -> Elem
row_view = |selected, key, item| {
    is_selected = Signal.select(selected, key)
    Html.div([Html.class_attr_s(is_selected.map(|s| if s { "row selected" } else { "row" }))], [
        Html.text_s(item.map(|i| i.label)),
    ])
}
```

Changing `selected` dirties two `is_selected` members and runs zero row
closures, whatever the list length.

## The Roc Platform Layer

The platform turns the app's pure description into a retained descriptor tree,
hands it to the host once, and provides the retained closures the host calls
back into. The platform has three responsibilities and no reactive runtime of
its own.

### 1. The descriptor tree as an explicit value

`Signal(a)` is an opaque descriptor that references a state/source binder or a
derived expression. Roc does not thread an ordinal counter while building the
tree; `build` returns a pure descriptor tree (`Elem` with embedded `SignalExpr`
edges), and the host assigns dense ids by walking identity-bearing construction
sites in deterministic pre-order. Each signal edge records its kind and inputs:

```roc
# Conceptual signal expression shape. Identity is carried by the same boxed
# initializer/transform allocation already required to evaluate each record.
SignalExpr := [
    Ref(U64),                                          # bound to a host source node id
    ConstValue({ value : HostValue, eq : EqThunk }),
    Map({ input : SignalExpr, transform : MapThunk, eq : EqThunk }),
    Map2({ left : SignalExpr, right : SignalExpr, transform : Map2Thunk, eq : EqThunk }),
    Combine({ inputs : List(SignalExpr), eq : EqThunk }),
]
```

`MapThunk`/`Map2Thunk`/`EqThunk` are boxed monomorphized closures (the confined
erasure). They are produced from `Signal.map`/`map2`/`Ui.state` at the call site,
so their input and output types are pinned to the surrounding `Signal(a)`. A
source's initial value, sink reads, event payloads, structural conditions, and
immutable `Rows` generations are carried as opaque `HostValue`
handles, each
paired with the per-edge **capability** (clone/split, equality, drop) plus any
capability-owned extension record for the edge-specific operation — see *The
capability* under Confined Erasure. The conceptual `eq` fields above are the
equality member of that capability, not a free-floating thunk. A `HostValue` is
**not** a literal
`Box(OpaqueValue)` field in the heterogeneous descriptor tree; Roc cannot erase
`Box(a)` that way. The value is produced at the monomorphized edge and stored in
a host value cell; the descriptor carries only the opaque handle plus the
capability that owns it.

The platform does **not** evaluate the graph. It only describes it. There is no
`eval_signal`, no dirty propagation, no cache in Roc.

### 2. Entry point

There is exactly **one** Roc entrypoint. The host owns the mutable node table
and drives every event in-process, calling retained Roc closures directly. There
is deliberately no per-event Roc entrypoint and no `ui_recompute` round-trip.

```roc
# platform/main.roc
roc_ui_init : () -> Box(Elem)
```

- `roc_ui_init` runs `main()` once and returns the boxed descriptor tree. The
  host ingests it, mints dense ids, resolves callable addresses to shared records,
  builds adjacency and topological ranks, computes initial values by calling the
  retained transform thunks in dependency order, and emits the initial render
  patches.
- **Per event there is no Roc entrypoint call.** A bound DOM listener fires; the
  host routes the event id to its source node (O(1)), calls that source's
  retained reducer thunk directly through `RocErasedCallable`, then propagates in
  rank order, invoking only the changed derived nodes' retained transform thunks.
  Every Roc call per event is a direct closure invocation, not an FFI entrypoint
  crossing.
- **Dynamic structure (`Ui.each` rows, `Ui.when` branches) also needs no
  entrypoint.** When a new list key or branch appears at runtime, Roc must
  *produce new UI structure* that did not exist at init — but it does so through a
  **retained builder closure**, not a new entrypoint. The row builder you pass to
  `Ui.each` and each branch body of `Ui.when` are captured at
  init as `RocErasedCallable` values. For `Ui.each`, the host first reconciles
  immutable `Rows` generations through the retained snapshot/delta operations;
  only when a key has no surviving row does it call `row` with the host-owned
  key text and a generation-checked `RowHandle`. The builder receives no item
  snapshot. It constructs `Ui.Row(item)` around the ordinary graph row source
  named by that handle and returns a fresh `Elem` sub-tree —
  the exact same kind of direct pointer call as a reducer, except it returns
  *structure* instead of a *value*. This is why no `roc_ui_each` or similar
  entrypoint is needed or wanted: the host already holds a direct pointer to the
  specific builder for that specific site. Adding an entrypoint would reintroduce
  the boundary crossing this model exists to remove, and force the host to ask
  Roc "which builder?" when it already knows. `Ui.each` patch locality is
  host-side: the host splices returned row sub-trees into affected scopes and
  preserves surviving row scopes instead of re-entering the root descriptor.
- **Why a single entrypoint, not a batched protocol.** A multi-entrypoint
  design (`init` / `event` / `recompute` / `drop`) with a batched recompute
  round-trip would exist only to amortize FFI cost. The in-process model makes
  that cost zero: there is no per-event entrypoint crossing to amortize, so
  batching machinery is unnecessary. The retained-closure-cost risk is answered
  by *not making the call a boundary crossing at all*, which is strictly cheaper.
  The hosted `roc_host_value_*` functions exist purely so Roc can mint/read/drop
  values in the host's value-cell registry; they are not a per-event dispatch
  path.

The mutable node table lives in the host, not in Roc. There is no `HostState`
box threaded through Roc; refcount and lifetime of retained closures follow the
existing ABI helpers in `roc_platform_abi.zig` (`allocateBox`, `decrefBoxWith`,
`increfErasedCallable`, `decrefErasedCallable`, `RocErasedCallable`). The host
drops the descriptor tree (and with it every retained closure) at shutdown.

### 3. Retained closures

Every callback the host ever needs is handed to it **once**, inside the `Elem`
descriptor that `roc_ui_init` returns, as a boxed Roc closure (`RocErasedCallable`:
a compiled-Roc function pointer plus its captured environment stored inline). The
host increfs and stores these in its node table and re-invokes them by direct
function-pointer call. The platform provides the trampoline that unboxes a thunk
and calls it with host-supplied inputs, using the `RocErasedCallable` machinery
already in the ABI (`callable_fn_ptr`, capture pointer, `on_drop`).

There are two kinds, invoked **identically** (the same direct pointer call), so
neither needs an entrypoint:

- **Value closures** — reducers (`Msg`), `map`/`map2`/`combine` transforms,
  capability operations, readers, and immutable-collection adapter operations.
  Take values or primitive sink tokens and return a value or next token.
- **Structure closures** — `Ui.each` row builders, `Ui.when` and
  `Ui.switch` branch builders, and `Ui.component` bodies. Take a key/row handle,
  a case value, or unit and return an `Elem` sub-tree. Run when a new
  row, branch, or component instance must be materialized at runtime.

The only difference between the two is the *return type* (a value vs. a piece of
UI). Both are pre-compiled Roc functions the host points at directly. This is the
key to the cost model: **all per-event and all dynamic-structure work is direct
closure invocation; the only exported entrypoint is the one-time
`roc_ui_init`.** A structure closure producing new UI at runtime is not a special
case requiring a generic door back into Roc — the host already holds the pointer
to the exact builder for that exact construction site.

Each signal record retains only its evaluator closure; its lookup identity is
derived from that owned callable rather than retained separately. Pending tasks
and active intervals take an additional callable ref while their lifecycle entry
can outlive the descriptor or record that supplied the pointer. Every owner drops
its ref via `decrefErasedCallable` when the record, request, or interval is removed.

## The Engine: Host-Agnostic Reactive Core

The engine is the mutable reactive runtime, factored as `Engine(comptime Ctx)`.
It owns identity, ownership, dirtiness, scopes, the keyed diff, and the
structural splice/collect/apply algorithms. It calls the host through the `Ctx`
contract and writes all output through `sink()`. It never knows whether it is
running under the simulated DOM or the browser.

The engine processes declarations and structural change through one transaction
boundary, but they affect different kinds of state. A **descriptor transaction**
ingests declarations for nodes, attributes, signals, and events. A descriptor
may be static (a fixed value) or dynamic (backed by a signal or retained event
callable); in either case it describes behaviour attached to an already chosen
tree shape. A **structural transaction** chooses or changes that shape: it
creates or retires scopes, selects a `Ui.when` branch, reconciles `Ui.each`
rows, transfers state ownership, and splices the affected graph and render
subtree. Structural work can therefore invalidate more indexes and ownership
relationships than publishing a descriptor, but it obeys the same
prepare-then-commit rule.

The engine's major abstractions divide into committed model, execution, and
host-facing services. Arrows show primary data flow rather than every internal
lookup; all boxes remain part of the one `Engine(Ctx)` ownership domain.

```mermaid
flowchart TB
    Ingress["ingress<br/>mount · event · source update · task result"] --> Tx["transaction coordinator"]

    subgraph Model["committed model"]
        Identity["identity tables<br/>node · DOM · construction site"]
        Desc["descriptor stream<br/>render nodes · attrs · events · scope sites"]
        Values["retained values and signal records<br/>capabilities · state cells · caches"]
        Scope["scope forest<br/>root · component · when branch · each row"]
    end

    subgraph Execute["execution"]
        Route["dense source and event routes"]
        Graph["active dependency graph<br/>adjacency · topological rank"]
        Schedule["dirty scheduler<br/>rank order · equality pruning"]
        Structure["structural reconciler<br/>when · keyed each · local splice"]
    end

    subgraph Services["host-facing services"]
        Effects["effect lifecycle<br/>tasks · timers · browser-backed sources"]
        Render["render cache and minimal diff"]
        Sink["transactional command sink"]
        Safety["limits · metrics · bounded diagnostics · poison"]
    end

    Tx --> Model
    Model --> Execute
    Route --> Schedule
    Graph --> Schedule
    Schedule --> Structure
    Schedule --> Effects
    Schedule --> Render
    Structure --> Model
    Structure --> Render
    Effects --> Sink
    Render --> Sink
    Safety -.-> Tx
    Safety -.-> Sink
```

Descriptors and structure use the same transaction boundary, but make different
promises. Static and dynamic descriptors both attach behaviour to a tree shape
that has already been selected: “dynamic” here means signal-backed or
callable-backed, not that it changes which elements exist. Structural work owns
changes to that shape and its lifetime topology.

```mermaid
flowchart LR
    subgraph Declarations["descriptor work — selected shape stays fixed"]
        Static["static descriptors<br/>elements · text · fixed attrs"]
        Dynamic["dynamic descriptors<br/>signal sinks · event callables"]
        Static --> DescriptorPlan["descriptor plan"]
        Dynamic --> DescriptorPlan
    end

    subgraph Topology["structural work — shape or ownership changes"]
        Trigger["state/component creation<br/>when selection · each key-set change"]
        Builder["retained structure builder<br/>produces an Elem subtree"]
        Trigger --> StructuralPlan["structural plan<br/>scopes · row/state ownership · local splice"]
        Builder --> StructuralPlan
    end

    DescriptorPlan --> Prepare["shared prepare phase<br/>validate · check limits · reserve · retain provisionally"]
    StructuralPlan --> Prepare
    Prepare -->|"failure"| Abort["abort without publication<br/>release provisional ownership"]
    Prepare -->|"success"| Commit["allocation-free commit"]
    Commit --> Publish["publish one generation<br/>engine indexes + complete command batch"]
```

The two plans are conceptual lifetime and atomicity domains, not permission to
implement two engines. They share identity, ownership, validation, and commit
machinery. Before `Commit`, neither persistent engine indexes nor host-visible
commands may reveal a prefix of either plan. After `Commit`, the engine state
and the command batch describe the same complete generation.

### Node table and graph

Per node id the host stores:
- kind (source / map / map2 / combine / selector / sink),
- forward adjacency (source id -> list of dependent ids) built from the desc,
- a topological **rank** (height) computed once at ingestion (the desc is a DAG;
  cycles are a host error),
- the cached current value (boxed opaque Roc value),
- the retained transform thunk (for derived nodes) or reducer thunk (for
  sources),
- the owning scope id.

A **selector** node owns a string-key→member hash index and a cached current key.
On a key change it looks up the previous and next members (O(1) each) and
enqueues only those two; members are ordinary `Bool` nodes whose transform is
host-owned and never calls into Roc. The host uses the capability-owned string
reader to expose the old and new opaque input values, so `derived_calls_into_roc` for a
selection change is independent of member count.

Selector keys are strings for the same boundary reason as `Ui.each` keys:
the capability-owned reader exposes UTF-8 bytes without the host inspecting an
opaque Roc value, after which the host hashes and compares those bytes itself. A
generic key constrained only by `is_eq` cannot provide a host hash index and
would force the forbidden O(M) member scan.

Adjacency, ranks, and the dirty set are dense integer-indexed structures. The
callable address is used only to preserve signal aliasing while descriptors are
ingested; active graph/node/runtime identities remain host-owned dense integers.
The app provides text key material to `Ui.each` and `Signal.select`; graph
execution does not scan to rediscover identity or use Roc `Dict(Str, _)` values.

### Complexity Discipline (the foundation budget)

The scaling claim must be true *in the data structures*, not only in the
algorithm. Every host path owes an explicit complexity budget, and a path that
exceeds its budget is a defect of the same severity as a wrong output — it
silently breaks Constraint 3. A path that is "linear in the changed set" on paper
but reaches that set through a linear scan of all nodes, a linear pointer→id
lookup, or a full graph rebuild does not meet its budget.

The budgets, by operation (N = total live signal records/render nodes in the
active tree; C = changed set for this event; K = rows touched by a structural
change; L = rows at the affected `Ui.each` site):

| Operation | Required budget | Forbidden |
|---|---|---|
| record/elem identity → id lookup | O(1) | linear pointer scan over the node table |
| descriptor lookup by `elem_id` | O(1) | linear scan over the descriptor arrays |
| non-structural event propagation | O(C + fanout) | O(N); O(fanout²) dedup/sort |
| selector key change (M members) | O(1) members dirtied, 0 derived Roc calls, O(1) capability reads | O(M) member recompute or `is_eq` scan |
| `Ui.when` branch flip | O(changed subtree) | O(N) field/route/graph rebuild |
| `Ui.each` direct-parent delta | O(edit operations + touched key bytes + affected scopes/fanout) | O(L) snapshot scan or O(N) global work |
| `Ui.each` snapshot/stale sibling | O(L) via exact key hash index | O(L²) `is_eq` scan |
| `Ui.each` append/remove/filter | O(K) after explicit `Rows` edits | O(N) per touched row |
| `Ui.each` reorder | O(K moved) DOM moves | O(L) whole-site re-collect + rebuild |
| dependency-graph maintenance after a splice | O(affected scope) | full clear-and-rebuild of the active graph over N |
| host allocation / free bookkeeping | O(1) per alloc/free | O(live allocations) scan per free |
| spec/bench action target resolution | acceptable O(DOM) for the *harness*, but excluded from `dispatch_apply_ns` | folding harness lookup time into measured framework cost |

Non-negotiable structural rules that follow from the budget:

- **Identity is resolved through stored ids, never rediscovered.** A signal
  record, a render node, and a DOM element each carry (or index into) their dense
  id directly. The host must never answer "what id is this record?" by walking a
  list comparing pointers, and never answer "what descriptor owns this elem_id?"
  by scanning a descriptor array. Both are the "scan to rediscover identity" that
  Constraint 2 forbids, restated as a performance invariant.
- **The dependency graph is maintained incrementally.** A structural splice
  edits only the records in the affected scope and patches their adjacency/rank
  in place. There is no clear-and-rebuild of the whole active signal graph on a
  structural change. Initial ingestion may be O(N); nothing after it may be.
- **`Ui.each` carries a host-private key hash index.** The key text is
  load-bearing, not decorative: the host hashes it into a `HashMap` for each
  each site and compares exact UTF-8 bytes to resolve collisions and duplicate-key
  checks. Direct-parent deltas address stable slots without scanning this index;
  snapshots use it for exact reconciliation. Linear equality-only matching is a
  budget violation. Dropping the hash index is a regression to fix, not a host
  workaround to absorb.
- **Reorder moves, it does not rebuild.** A pure permutation of surviving rows
  must emit only DOM moves for displaced rows (computed against a longest-stable
  subsequence so unmoved rows cost nothing) and must not re-collect row
  descriptors or rebuild the site's signal graph. Whole-site replacement is
  reserved for the case where the *set* of rows changed in a way that genuinely
  cannot be expressed as moves-plus-local-splices, and that case must be named
  explicitly and asserted, never reached by falling through.
- **Allocation bookkeeping is O(1).** The host's allocation ledger (used for
  leak accounting and the allocation metrics) must support O(1) free; storing the
  ledger index in the allocation header is the expected shape. An O(live) scan
  per free makes session cost O(allocs²) and poisons the very allocation
  telemetry it feeds.

### Propagation algorithm (push-based, glitch-free, value-pruned)

On a source update:

1. Set the source node's value; push it on a priority queue keyed by topological
   rank.
2. Pop nodes in increasing rank order. For each derived node whose input changed,
   request its recompute (batched) from Roc with input values already in the
   table.
3. If the new value is `is_eq` to the cached value, **stop** — do not dirty its
   dependents. Otherwise update the cache and enqueue its dependents.
4. For sink nodes whose value changed, emit the minimal render command (`SetText`,
   `SetValue`, `SetChecked`, `SetDisabled`, attribute set) through `sink()`.

Rank ordering guarantees a diamond (`a->b`, `a->c`, `(b,c)->d`) recomputes `d`
exactly once after both `b` and `c` settle — glitch freedom at runtime with no
re-sort. Value pruning is the second half of linear-with-changes scaling.

### Event routing

The host maintains dense event binding tables built from canonical
`Node.Attr.On(EventBinding)` descriptors. Fixed and named bindings both resolve
to retained event descriptors; when a DOM listener fires (a simulated one on the
native host, a real one in the browser), it looks up the event id in O(1),
validates the boundary payload descriptor, and calls the source's retained
reducer thunk directly. No scan, no string lookup.

### Scopes and lifecycle

The host owns a forest of scopes: the root, each `Ui.component` body, each
live `Ui.when`/`Ui.switch` branch, and each `Ui.each` row. On a branch
change or a key-set change:
- diff the new structure against the old (key-set diff for lists, branch flip for
  conditionals),
- mint a scope for new branches/keys (run that scope's `build` once, ingesting
  the sub-desc Roc returns for it),
- dispose scopes for removed branches/keys: remove their ids from active indexes
  and adjacency, call `decrefErasedCallable` on each retained closure (Roc
  reclaims captured environments), release capability-owned state/source values,
  run any `Ui.on_cleanup` task, and detach the rendered subtree through `sink()`,
- reorder list rows by moving DOM nodes, never rebuilding surviving rows.

Dense id tables are allowed to keep their backing arrays, but inactive slots are
not allowed to grow without bound. Disposed each-row scopes, state cells, node
identities, DOM identities, native simulated DOM elements, component scopes, and
`when` branch scopes become reusable slots while id-indexed reads remain O(1).
Reclamation must never be implemented by scanning all live nodes or rebuilding
the graph.

Each keyed site and row keep only the local topology needed for sparse work:

```text
EachSite
    stable generational site id
    committed/candidate Rows owners
    exact-key hash index
    intrusive row-order head/tail

RowEntry
    row handle and scope id
    host key slot
    adapter item slot
    previous/next row handles
```

Exact key bytes live in reclaiming site-owned storage for the row lifetime.
Delayed `Ui.Row.signal` reads resolve through the site's committed or candidate
owner plus stable item slot, so a captured row never contains a stale item
snapshot. One item is materialized only when an active row source reads it;
multiple `Ui.Row.map` projections share that ordinary graph source. Scope-child
adjacency, scope-owned descriptor indexes, per-row render-root anchors, and
sibling render links make insert/remove/move local: sparse edits may not scan a
whole scope, descriptor stream, each site, or global render order to find the
affected structure. Candidate overlays remain live through nested building,
propagation, render preparation, and allocation-free publication; the previous
owner is released only after all of those phases succeed.

`keep_alive` is an explicit per-scope flag, never a heuristic.

**Leak invariant:** the host holds exactly one refcount per live retained
closure/value and zero for disposed ones. The graph is a DAG; the host's
back-references are not Roc-visible, so there are no refcount cycles.
Reclamation is deterministic, no GC.

### The render-command sink

The engine never touches a DOM directly. It writes to a `sink()` the host
supplies. The command set is the typed, host-independent vocabulary:
`ResetDom`, `CreateElement`, `CreateText`, `AppendChild`, `RemoveNode`,
`MoveBefore`, `SetText`, `SetValue`, `SetChecked`, `SetDisabled`, `SetRole`,
`SetLabel`, `SetTestId`, `SetClass`, pointer-event binds, timer/task commands,
and event bind/clear operations. The browser wire also has an `Extended` fixed
record whose operands point at a dynamic byte record for less common operations
such as arbitrary text attributes. The shared command vocabulary, command
counters, metrics accumulator, fixed-width command record, and dynamic-record
framing live in `src/signals/render_commands.zig`. Each host implements the
sink:

- the **native host** applies each command to its `DomElement` array, including
  a separate owned custom-attribute table for `Html.attr`/`Html.attr_s`/
  `Html.attr_maybe_s`;
- the **wasm host** serializes each command into a fixed-width record in linear
  memory for the JS executor to apply, with dynamic byte records for metadata
  attributes (`role`, `aria-label`, `data-testid`, `class`) and open-ended
  custom text attributes. Optional signal-backed custom text attrs lower to the
  same set/clear command vocabulary: `None` removes the attr, `Some(text)` sets
  it.

Because the logical command set is shared, a spec on the native host asserts the
same render semantics the browser will execute. The browser wire can choose a
compact fixed record or an `Extended` dynamic record without changing the engine
or native host semantics.

### Metrics

The host retains a metrics record for benchmarking. The meaningful counters
are: `events_processed`, `propagation_prunes` (`is_eq` short-circuits),
`derived_calls_into_roc` (direct retained-thunk invocations per event, which
should track changed nodes rather than graph size), `recompute_batches`,
`patches_emitted`, render command counters (`reset_dom`, `create_element`,
`append_child`, `remove_node`, `move_before`, `set_text`, `set_value`,
`set_checked`, `set_disabled`, `set_metadata`, `bind_event`),
`scopes_created`, `scopes_disposed`, `rows_reused`, `rows_created`,
`rows_removed`, `closure_retains`,
`closure_releases`, and `retained_alloc_delta`. `rows_reused` must count actual
subtree reuse — a row is only counted as reused when its scope (and local state)
is preserved across the update. These counters are what the simulated host buys
us: they let a spec assert *exactly* how much work an event caused, which is the
property we most need to prove and which a real browser would not expose.

`Rows` reconciliation additionally exposes
`rows_delta_batches`, `rows_snapshot_batches`, `rows_edit_candidates`,
`rows_edits_applied`, `rows_snapshot_items_scanned`, `rows_keys_copied`,
`rows_key_bytes_copied`, `rows_key_bytes_validated`, `rows_items_compared`,
`rows_items_materialized`, `row_sources_dirtied`, `row_builders_called`,
`rows_order_links_touched`, and `rows_render_roots_moved`. These distinguish
sparse transition cost from snapshot fallback and make key copying, item
materialization, graph fanout, order maintenance, and DOM movement independently
auditable.

Counters that measure update amplification (`patches_emitted`,
`derived_calls_into_roc`) are necessary but not sufficient: they count *emitted* and
*recomputed* work, so an O(N²) splice or a full graph rebuild can sit underneath a
low patch count undetected. The telemetry must therefore also expose the
foundation-level work the Complexity Discipline budget governs — *scanned* nodes,
*rebuilt* graph records, key compares, and allocations per event — each named so a
spec can assert a hard bound:

- **`active_graph_records_rebuilt`** — number of signal-graph records whose
  adjacency/rank was (re)constructed this event. For a non-structural event this
  is `0`; for a local structural splice it is bounded by the affected scope, not
  by N. A spec asserting `expect_metric_delta active_graph_records_rebuilt 0` on a
  single-row item change is the canary that fails loudly if a full
  clear-and-rebuild path is introduced.
- **`stream_nodes_scanned`** — number of descriptor/render-node entries visited
  while applying this event's patches. This is the counter that exposes
  full-stream scans hiding behind a low `patches_emitted`.
- **`each_key_compares`** — `is_eq`/hash probes performed in keyed diffs this
  event. With a hash index this tracks L; linear matching makes it track L²,
  which a spec can pin.
- **`allocs_this_event` / `deallocs_this_event`** — per-event allocation deltas,
  so "allocations per event are flat" is an assertion rather than an assumption.
- **`selector_members_dirtied`** — member nodes enqueued by selector key
  changes this event. A spec asserting `expect_metric_delta
  selector_members_dirtied 2` alongside `derived_calls_into_roc 0` on a
  selection change in a large list is the canary for Product Goal 3.

Telemetry placement is deliberate:

- **Spec assertions (`expect_metric_delta`)** carry the scaling *invariants* that
  must hold regardless of timing:
  render command counters, `derived_calls_into_roc`, `rows_reused/created/removed`,
  `active_graph_records_rebuilt`, `stream_nodes_scanned`, `each_key_compares`,
  and per-event allocation deltas. These fail the build when a path does O(N)
  work where the budget allows only O(changed).
- **Benchmark CSV only** carries the *timing and aggregate* evidence:
  `dispatch_roc_ns`, `dispatch_apply_ns`, total allocs/deallocs, command
  category counts. Timing corroborates but never gates — a check that can pass
  while real work grows is worse than no check, so timing is never the primary
  guard.

`retained_alloc_delta` measures the allocation residue of a single init-and-replay
cycle, not growth across a long session. Proving "retained memory over a long
session is flat" requires a distinct experiment that reuses one `HostEnv` across
many events and watches the live `allocs − deallocs` gauge over time (see Measures
of Effectiveness); per-iteration deltas cannot establish it.

`Rows` timing evidence uses ReleaseFast Zig and Roc `--opt=speed` builds against
the durable official `js-framework-benchmark` checkout and downloaded browser
artifacts. All nine Node/Wasm and official-browser operations are reported, with
every sample, median/range, script/paint/total time, weighted geometric mean,
allocation traffic, retained memory, wire bytes, and the `Rows` counters above.
Canonical keyed Solid is the primary comparison and solid-store the secondary.
Update, swap, remove, and append target no worse than 2× Solid, with 1.25× as the
stretch target; create, replace, selection, startup, compressed size, and memory
may not materially regress. If counters prove O(changed) work but browser time
does not improve, profiling the remaining cost is required before the
performance objective is complete.

## Glitch Freedom, Ordering, and Async

- **Glitch freedom:** topological-rank scheduling, computed once at ingestion.
- **Update ordering:** a single dirty priority queue per propagation; effect
  results and timer ticks enter the same queue, so there is one ordering
  authority.
- **Async / cancellation:** `Cmd` requests carry a host-assigned request id tied
  to the owning scope and source node; that request id is the lifecycle and
  cancellation authority. Routing is by the request's dense effect-registry
  id; a human-readable kind label travels only for diagnostics and native spec
  control, never for dispatch. Disposing the scope cancels the request. `Sub`
  descriptors follow the same structural ownership rule: declared by
  structure, diffed by the host against the live set, and started/stopped by
  scope lifecycle.
- **Errors:** `Signal.from_task` yields `[Loading, Done(a), Failed(err)]`, so error
  states are ordinary signal values the app folds and renders. There is no
  effect-inside-signal-evaluation; effects are sources.

## Native Host Specifics

The native host is the engine plus a simulated DOM, a spec runner, and
telemetry. It is the place where we prove semantics and characterize work,
because it can observe things a real browser structurally cannot.

- **Simulated DOM.** A flat array of `DomElement` records (tag, role, label,
  test_id, text, value, checked, disabled, parent, children, bound events,
  per-field update counters). The native sink applies render commands to this
  array exactly as a browser host applies them to a real DOM.
- **Spec runner.** A semantic-locator spec parser (`role:`, `label:`, `text:`,
  `test_id:`, and `expect_*` / `click` / `fill` / `check`) that lets a spec
  assert UI behavior in user-facing terms and assert the exact work an event
  caused via `expect_metric_delta`. Spec actions (`click`, `fill`, `check`) fire
  the bound event id into the source node's retained reducer thunk.
- **Allocation ledger and telemetry.** The O(1) allocation ledger and the
  work counters above. This is the observability surface; it does not exist in
  the browser host.

These are native-specific and are **not** part of the browser host.

## Wasm Host and Browser Boundary

The wasm host is the engine plus the JS↔WASM boundary. The framing is **host
owns logical identity; JS owns DOM identity; they stay in lockstep by integer
ids**. The JS runtime is a thin executor of the engine's command stream — it
holds no reactive state, runs no diff, and never reconstructs meaning.

```
  Roc app (wasm)         Engine (Zig, in wasm)              JS runtime (browser)
  --------------         ---------------------              --------------------
  main : () -> Elem      node table (mutable)               nodes[]   : Node[]
  pure descriptor   ──▶  scheduler / dirty set / scopes ──▶ listeners[]: Fn[]
  (roc_ui_init, once)    reducer + transform thunks         applyCmd(op, args...)
                         keyed each diff, ranks              forward event(id,payload)
  retained closures ◀──  host calls them in-process
  (no per-event FFI)     emits patch ops ─────────────────▶ exactly one DOM call per op
```

### Boundary contract

- **WASM exports a tiny integer-only control surface; JS never calls
  `roc_ui_init` directly.** JS asks the host to init; the Zig host calls
  `roc_ui_init` inside WASM, exactly as the native host does.
- **WASM owns logical identity; JS owns DOM identity, kept in lockstep by integer
  ids.** JS holds `nodes: (Node|null)[]`; the host holds dense node ids. DOM
  nodes never cross the boundary.
- **The crossing is a patch-op stream (host→JS) plus an event call (JS→host).**
  Not a serialized tree, not a pull-based inspection API, not a JS-side diff.

### Host C-ABI exports

```
roc_ui_mount() -> void          // host runs roc_ui_init, ingests, emits initial patch stream
roc_ui_event(event_id, payload_kind, payload_ptr, payload_len, bool_value) -> u32
                                // DOM-response bits; static-policy handlers return zero
roc_ui_timer(token) -> void                 // drive interval/timer source
roc_ui_resolve(request_id, ptr, len, failed) -> void   // async result
roc_ui_unmount() -> void        // dispose all scopes, drop descriptor, free retained closures

roc_alloc / roc_dealloc / roc_realloc        // marshalling
memory                                       // exported linear memory

roc_ui_protocol_version() -> u32
roc_ui_protocol_features() -> u32
roc_ui_command_record_words() -> usize
roc_ui_command_buffer_ptr() -> usize
roc_ui_command_buffer_len() -> usize
roc_ui_string_buffer_ptr() -> usize
roc_ui_string_buffer_len() -> usize
roc_ui_dynamic_buffer_ptr() -> usize
roc_ui_dynamic_buffer_len() -> usize
roc_ui_last_error_ptr() -> usize
roc_ui_last_error_len() -> usize
roc_ui_live_host_values() -> usize
```

The host drives the engine entirely inside WASM. `roc_ui_event` enters the Zig
host, routes the event id to its source node, calls the retained reducer thunk
via `RocErasedCallable` in-process, and returns synchronous DOM-response bits to
JS before the command drain. JS accepts only the response controls that can still
affect the active browser event (`preventDefault`, `stopPropagation`, and
`stopImmediatePropagation`) and fails closed on any other returned bit.
Static-policy handlers return zero; a handler whose policy is decided by the
reducer returns the bits it chose, and that is the only dynamic-response path. There is no per-event Roc entrypoint crossing —
this is the reason the boundary is cheap.

### Command-buffer wire format

The browser wire is versioned. JS reads `roc_ui_protocol_version()` and
`roc_ui_protocol_features()` before mounting and requires the exact protocol
version it was built against plus the feature bits it depends on (such as
`dynamic_attrs` and `dynamic_events`). A version or feature mismatch is a boundary
error, not a compatibility shim.

The host appends fixed-width records to `roc_ui_command_buffer_*`: six little
endian `u32` words (`op`, then five integer operands). Hot operations fit
entirely in those operands. Free-form text for hot string ops (`CreateElement`,
`CreateText`, `SetText`, `SetValue`, task name/request) is stored in
`roc_ui_string_buffer_*`, and fixed records carry `(offset, len)` slices into
that buffer. JS never decodes a `RocStr` header, tag union, list layout, or Roc
payload to infer meaning.

Less common variable-shape commands use fixed op `Extended`. Its operands are:

```text
record.op = Extended
record.a  = byte offset in roc_ui_dynamic_buffer_*
record.b  = byte length of this dynamic record
```

Each dynamic record is self-framed:

```text
u16 dynamic_op
u16 flags       # reserved; must be zero
u32 payload_len
payload bytes
zero padding to 4-byte alignment
```

The dynamic-record protocol defines two dynamic attribute ops and two dynamic
event ops:

```text
SetAttrText:
  u32 elem_id
  u32 name_len
  name bytes
  u32 value_len
  value bytes

RemoveAttr:
  u32 elem_id
  u32 name_len
  name bytes

BindEvent:
  u32 elem_id
  u32 event_id
  u32 event_name_len
  event_name bytes
  u32 listener_options
  u32 delivery_requested
  u32 delivery_effective
  u32 delivery_reason
  u32 event_extraction_plan_len
  event_extraction_plan bytes

ClearEvent:
  u32 elem_id
  u32 event_name_len
  event_name bytes
```

Strings in dynamic records are UTF-8 byte slices. The runtime validates the
header, flags, aligned outer length, payload consumption, operand bounds, and
UTF-8 before touching the DOM. Unknown dynamic ops and malformed records are
reported as contract errors. This keeps JS a decoder/executor for explicit data
the host emitted; it does not reconstruct missing render intent.

The wasm host emits dynamic records for metadata text attributes
(`role`, `aria-label`, `data-testid`, and `class`) and for app-authored custom
text attributes from `Html.attr`, `Html.attr_s`, and `Html.attr_maybe_s`. The
Roc descriptor makes the custom path explicit with `Node.field_custom` plus a
`name` field on text attrs; fixed text fields must carry an empty name.
`SetText`, `SetValue`, bool fields, fixed click/input/check/pointer event binds,
timers, and tasks remain fixed records when they can be represented without
policy/delivery/payload expansion. General named events, and fixed events that
need the expanded shape, use `BindEvent`/`ClearEvent`, carrying the event name,
listener option bits derived from typed policy, delivery
requested/effective/reason ids, and extraction-plan bytes emitted by the host
from Roc descriptors. JS derives the dispatch payload kind from the validated
extraction plan.

Wire-size optimizations are command-stream concerns, not value-model concerns.
The runtime telemetry records fixed-record bytes, fixed-string bytes, dynamic
buffer bytes, and apply-path decode counts/bytes for fixed strings, dynamic
records, dynamic strings, and dynamic byte arrays. Any string-dedupe
optimization must be justified by representative action telemetry, not mount
snapshots alone, and must lower total command/decode bytes without globally interning Roc
strings, `HostValue`s, keys, or capability-owned data.

Dynamic event payload descriptors are independent of Roc value layout. They are
small byte descriptors that name only event/target/currentTarget leaves JS may
read. The descriptor vocabulary supports unit payloads, scalar text/bool
payloads, and explicit records. The record descriptor used by
`Html.on_key_down` asks JS to read `event.key` and `event.shiftKey`; JS encodes
`{ key, shift_key }` as:

```text
u32 key_utf8_len
key UTF-8 bytes
u8 shift_key   # 0 or 1
```

The host receives those bytes as a `List(U8)` `HostValue`, and the app-facing
`State.on_key` decoder constructs the typed Roc record. JS never decodes Roc
records, tag unions, list headers, or string layouts. Unsupported payload kinds,
malformed descriptors, invalid source/leaf pairs, duplicate record fields,
trailing bytes, and invalid listener option bits are host/runtime contract
errors.

### Marshalling and memory discipline

Any `roc_alloc` during a host call can grow linear memory and detach JS
typed-array views. The rule is **rebuild cached views after every allocating
host call, before reading any command buffer or string/payload bytes** — JS
compares `memory.buffer` identity and rebuilds `Uint8Array`/`Int32Array`/
`DataView` only when it changed. No host-bumped memory-generation export is
required.

### Memory management and allocation failure

Allocation failure is part of the host contract, not an unchecked implementation
detail. Separating memory by lifetime prevents scratch aliases from escaping and
prevents partially built output from becoming observable. Memory belongs to one
of three lifetime domains, and a value never moves between them by implication:

- **Persistent engine memory** owns committed graph records, scopes, retained Roc
  values, identities, and render-cache state. Its owner releases it when the
  record or scope is retired, or when the instance is torn down.
- **Transaction scratch memory** owns temporary queues, descriptors, diff state,
  and staged commands for one externally initiated operation. Capacity may be
  retained for reuse, but logical contents end with the transaction and cannot
  become persistent aliases.
- **Published boundary memory** is an immutable view of one successful command
  batch. It remains readable until the browser acknowledges or clears it and is
  never also used as the next transaction's writable staging area.

Every mount, event, timer tick, task result, browser-source update, and unmount is
a **host transaction** with prepare, mutate, and publish phases. Preparation
validates sizes with overflow-safe arithmetic and reserves every capacity that
can be derived before mutation. It may evaluate Roc readers and transforms whose
contract is pure: their provisional results remain transaction-owned and are
released on abort. Callbacks that start effects, issue commands, or otherwise
make externally observable changes never run during recoverable preparation.
Only after preparation succeeds may persistent ownership change, the graph or
render cache mutate, or a sink become visible. Publication is a single commit:
before it, commands are private scratch; after it, the complete immutable batch
is visible. The browser applies only a successful published batch and never
observes or executes a prefix from a failed transaction.

One host transaction may run several engine transactions in sequence: the
lifecycle callbacks of a mount or structural change dispatch state, issue
storage or navigation commands, and those commands refresh browser sources,
each as its own prepare-then-commit step. The engine commits each step by
sealing its commands onto the host call's staged batch without allocating; a
step that fails preparation aborts back to the previous seal, leaving the
earlier steps intact. Effect commands a sink emits after a step sealed append
and seal the same way. Only the host publishes, once, when its call ends, so
the browser sees the whole host transaction as one batch and never a partial
sequence of steps.

An allocation failure during preparation is **recoverable when the allocating
call has an error-and-unwind channel**. Host-owned allocation, copying, and
preflight use that channel: they return `out_of_memory`, publish no commands,
invoke no effectful callback, release all provisional results, and preserve the
previous committed engine and DOM state. Owned replacements follow
allocate-copy-commit-release order, so failure cannot destroy the old value. A
recoverable transaction may be retried when memory becomes available; pure
evaluators may therefore run again and must not encode once-only effects.

Recoverability is a property of the call boundary, not merely of when the
allocation occurs. Code entered through an ABI that cannot report allocation
failure or unwind owned values crosses a fatal containment boundary for the
duration of that call. In particular, a pure Roc reader may allocate while its
erased callback has no OOM result channel. Failure there poisons and traps the
instance, but still clears staged publication and leaves the last committed DOM
as the only observable state. The platform allocator handles this failure
itself: `roc_alloc` and `roc_realloc` must enter bounded fatal containment and
must not return a null or failed allocation result to compiled Roc code. A
callback ABI could make such failures recoverable only by defining explicit
failure and ownership-unwind semantics; host policy must not infer them from
callback purity alone.

An allocation failure after an irreversible ownership or mutation boundary is
**fatal**. Continuing a partly mutated refcounted graph would be memory-unsafe,
so the host clears published lengths, records a bounded diagnostic, marks the
instance poisoned, and traps. A poisoned instance accepts only allocation-free
diagnostic reads and idempotent containment/teardown operations; it never resumes
engine execution.

Diagnostics have storage reserved at instance creation and require neither heap
allocation nor unbounded formatting. The browser catches every fatal host trap,
refreshes memory views before reading the diagnostic, reports the error, detaches
listeners and asynchronous work, ignores staged commands, and rejects later
calls without re-entering Wasm. It may preserve the last committed DOM as fallback
UI or replace the entire Wasm instance. Fatality is scoped to that invocation and
instance: it does not require terminating the JavaScript thread, worker, page, or
surrounding application. Recovery creates a fresh instance or chooses a host-side
fallback; it never resumes the poisoned instance. A trap is therefore the
containment mechanism for unrecoverable corruption risk, never an unexplained
browser failure or permission to continue with uncertain state.

All caller-controlled node counts, descriptor bytes, payload/text bytes, command
records, and dynamic command bytes have configurable limits beneath hard wire and
address-space maxima. Limit checks precede allocation and distinguish
`resource_limit` from allocator exhaustion. Linear-memory growth is an allocator
mechanism, not a resource policy. Persistent tables and retained scratch buffers
must also have plateau invariants so valid repeated activity cannot cause
unbounded growth.

Teardown is logically infallible: it allocates no memory, releases each owned
resource at most once, tolerates partially initialized preparation state, and is
idempotent at the containment boundary. Failure reporting and cleanup never
depend on successfully acquiring more memory.

The verification principle is exhaustive fault placement. A representative
transaction first records its successful allocation-attempt count, then runs
with attempt `N` and every later allocation attempt failing for every `N` from
one through that count. Allocation, resize/remap fallback, preparation,
mutation, publication, and teardown boundaries are included. Each outcome must
match its declared recoverable or fatal boundary and prove no leaks, double
release, partial publication, or invalid reuse. Bounded Wasm memory separately
proves the real `memory.grow` exhaustion path; overflow and configured-limit
tests prove rejection occurs before allocation. This method makes a newly added
allocation a newly exercised failure point rather than an implicit assumption.

### Diagnostics contract (legible failure)

Every contract error the host raises — duplicate key, capability mismatch,
malformed descriptor or payload, cycle, resource limit, poisoned instance —
is one structured diagnostic with three parts:

- an **error class** from a closed enum shared by both hosts;
- the **rule** broken, as a short fixed string that names the invariant in
  this document's terms;
- the **construction-site path**: the scope chain from the root (component
  name, `when`/`switch` case, each-row key), then the element tag, then the
  attribute, event, or signal edge that owns the fault.

The native runner prints it and lets specs assert on it; the browser runtime
reads it from the reserved diagnostic storage after a trap and prints the same
text to the console. Storage is reserved at instance creation and formatting is
bounded, so a diagnostic is available even when the failure was allocation.
An integer code alone, a bare trap, or a silent no-op is a contract violation
of the host itself.

### Controlled inputs

`SetValue` is a guarded op, not a blind assignment. Equal values are no-ops;
differing values are deferred while the target input is focused or composing
(IME); the latest deferred value is applied after blur unless a later input echo
already matched it. The guarded text-value rule applies to text-like controlled
controls, including text input, number-input draft strings, and textarea.

Other form controls stay on explicit field/event descriptors rather than a
browser-owned form model: single-value select uses the text `value` field and
target-value change payload, radio derives `checked` from a string-valued
selected signal and dispatches the option value, and checkbox uses the bool
`checked` field plus target-checked payload. Submit and reset are app-managed
form events with static prevent-default policy, and the native runner models
the same default actions the browser executor honours.

Every further input capability — focused masking and validation,
selection-preserving normalization, file inputs, multi-select, browser
constraint validation, date/time controls, app-visible focus commands — is
added as an explicit field, event, or command descriptor decided in the
engine and executed identically by both hosts. None is added as an executor
heuristic. Which of these earn a descriptor is a product question answered by
maintained apps; the design rule is only that the executor stays thin.

### Refcount ownership split

- The host holds exactly one refcount per live retained closure/value (the Leak
  invariant above). JS never owns Roc refcounts; JS holds DOM nodes and integer
  ids only. On `RemoveNode`, JS detaches the DOM node and clears `nodes[id]`; the
  refcount drop happens inside the host's scope-dispose path. That drop releases
  the value through its per-edge **capability** (see Confined Erasure), never by
  the host walking the payload layout: the prebuilt host cannot know how to free
  the nested fields of an app-typed `Box(a)`, so releasing it is a capability
  call.
- String buffers JS receives are borrowed for the drain; the host owns and frees
  them. Buffers JS produces for event payloads are `roc_alloc`'d by JS and
  ownership transfers to the host on `roc_ui_event`.

### Browser mounting model

One active browser mount owns one Wasm instance. The wasm host stores the engine
and capability stack in module-global state inside that instance, and
`roc_ui_mount()` starts by clearing that instance's active runtime before
running `roc_ui_init`. The browser convenience helper `mountSignalsApp` follows
this model by instantiating a fresh Wasm module for each root.

Multiple independent roots on one page are supported by creating multiple Wasm
instances and one `SignalsRuntime` per root. A single `WebAssembly.Instance`
must not be shared across simultaneous roots unless the host grows explicit
mount handles on every export and command buffer. That handle-based model is
adopted only if many-widget embedding measurements show that per-instance
memory/startup cost is unacceptable (see *Non-Goals* and *Open Questions*).

### Async in the browser

Effects are sources. Timers/`Signal.interval` are ingested at init; JS runs the
real `setInterval(period_ms)` keyed by `token` and calls `roc_ui_timer(token)`
each tick. Tasks declare a request with a registry kind id and request payload;
the host assigns a `request_id`, JS routes the request by its kind id to the
matching bridge, and on settle calls `roc_ui_resolve(request_id, ptr, len, ok)`,
which the host folds into `[Loading, Done, Failed]`. Browser HTTP tasks are the
registered kind whose bridge performs `fetch`.
Disposing a scope cancels in-flight requests (host-emitted cancel → JS
`AbortController` / `clearInterval`) and runs `Ui.on_cleanup`. All of it enters
the one propagation queue; JS scheduling stays a single synchronous path.

HTTP request policy comes from browser `fetch` defaults except for the
fields the Roc request envelope carries. The runtime passes method, headers,
body, timeout, and an abort signal; it does not set `credentials`, `redirect`,
`mode`, `cache`, or referrer policy. Therefore credentials default to
same-origin, redirects default to follow, and CORS remains normal browser CORS.
HTTP statuses are materialized as responses. Rejected fetches, including CORS
denials and network failures, become `HttpError.Network`; runtime timeouts
become `HttpError.Timeout`; and scope disposal or request replacement becomes
`HttpError.Canceled`.

Browser location is another host-backed source. `Browser.location()` is seeded
from the per-mount startup snapshot before `roc_ui_mount`, and the JS runtime
installs a mount-scoped `popstate` listener that calls
`roc_ui_update_location` with normalized `{ path, query, hash }` pieces.
`Browser.push_state` and `Browser.replace_state` travel through the command
boundary and call `history.pushState` / `history.replaceState`; the host also
refreshes active location sources in that propagation turn so rendered route
state and the browser URL stay aligned. When an `Ui.on_change` emits navigation
while a dirty batch is rendering, the engine applies scalar and structural
sinks for that generation before redispatching the updated location source.
This transaction boundary prevents a canonical redirect from invalidating a
pending `Ui.when` branch change.

`Browser.set_title` is a separate command, not part of location. Apps derive a
title from route or domain state and emit it with `Ui.on_change_initial` when
the first mounted value matters, or `Ui.on_change` when only later changes
should touch the title. The browser runtime writes `document.title`, and the
native spec host records the title for assertions.

Browser visibility and online/offline state are the other focused browser
sources. `Browser.visibility()` is seeded from `document.visibilityState`
and refreshed from `visibilitychange`; `Browser.online()` is seeded from
`navigator.onLine` and refreshed from `online` / `offline`. Both reuse the same
host-backed source path as location: mount-scoped ids/generations, shared
boundary payload bytes, stale-message diagnostics, and listener cleanup on
unmount. Each is an instance of the `Sub` model: declared by structure, owned by
its scope, routed by registry id.

`Browser.entropy_seed()` is an immutable host-backed source sampled once per
mount. The browser runtime obtains one `U32` from `crypto.getRandomValues`
before mount preparation; native semantic specs use a fixed seed. Roc owns all
subsequent deterministic PRNG state and selection, so row generation does not
cross into JavaScript or create a second scheduling path. The value is a seed
for pure randomized UI and simulation, not a token or secret API.

Browser storage reads are declared sources, not whole-store snapshots.
`Browser.local_storage_text(key)` and `Browser.session_storage_text(key)` add
specific key/area declarations to the prepared mount; the JS runtime reads
those keys synchronously before first render and passes `StorageMissing`,
`StorageValue`, or `StorageUnavailable` payloads to Roc. Storage writes and
removals are command-buffer operations, coalesced by area/key before touching
the browser store. Storage write/remove failures are host diagnostics, not
app-visible command results; an app that must know whether a write landed
declares the matching storage read source and observes it. Stored values are text; JSON, validation, and
key namespacing remain app/package responsibilities.

### What is worth testing on the JS side

The JS runtime is a thin executor, so engine semantics and work budgets are
proven by the native spec runner, **never re-tested through JS**. JS-side guards
belong to the **browser boundary contract**: the cmd/patch codec, protocol
version/feature negotiation, dynamic-record validation, event-payload
marshalling, static event-policy and response-bit timing, controlled-input DOM
reconciliation, behavior attach/update/cleanup, timer/task/fetch bridges,
telemetry byte accounting, and the `memory.grow` view-refresh discipline. A JS
test that re-asserts "clicking changes the count" or "one patch per event" is
duplicating the engine's own coverage across the boundary and pulls no
additional weight.

## Measures of Effectiveness

These are the outcomes by which we judge whether the platform meets its intended
goals. Each is a property we can observe and that should hold for the life of the
platform; each is backed by a spec, host test, or measurement that fails if the
property regresses.

1. **One engine, two thin hosts.** All reactive and structural logic lives in the
   shared engine. Neither host file contains reactive or structural logic; each
   is a `Ctx` + `sink()` implementation plus its boundary. *We know this holds
   when:* the hosts cannot drift apart, because there is only one implementation
   of behaviour to drift from, and the same engine instantiates under both the
   native build and `wasm32`.

2. **Same apps, both environments.** The app suite is written once in Roc and runs
   under the native spec runner and in the browser. *We know this holds when:*
   every app in the suite builds and runs in both, with `scripts/serve.py` able to build
   and serve any app, not just one.

3. **Semantics proven where we can observe them.** The native spec runner asserts
   behaviour and work budgets — the observability a real browser structurally
   cannot give us. The JS runtime is thin enough that automated JS tests stay on
   browser-boundary responsibilities rather than engine semantics. *We know this
   holds when:* engine semantics are covered by native specs, and JS coverage is
   limited to the codec, DOM executor, browser resource bridges, telemetry, and
   fail-closed boundary validation.

4. **Work scales with change, not tree size.** Per event, nodes recomputed,
   patches emitted, and rows touched track the *changed* set — including under
   list churn — never graph or tree size, with no full-tree re-walk, no full
   graph rebuild, and no scan-to-rediscover-identity. *We know this holds when:*
   `expect_metric_delta` assertions over `derived_calls_into_roc`,
   `active_graph_records_rebuilt`, `stream_nodes_scanned`, `each_key_compares`,
   and the row counters bound work to the changed set, and per-event allocations
   are flat across input size.

5. **No leaks; reclamation is deterministic.** The host holds exactly one
   refcount per live retained closure/value and zero for disposed ones. *We know
   this holds when:* `closure_retains == closure_releases` after teardown, the
   live `allocs − deallocs` gauge and host retained-byte gauge are flat after
   warmup across a long session, dense table lengths plateau under repeated
   event dispatch, keyed-row reorder churn, bounded removal/reinsert churn, and
   nested branch-scope churn, and carrier type-tag assertions never fire across
   the full safe-build spec suite.

6. **Determinism.** The same spec produces the same command sequence every run.

7. **Confined erasure cannot crash.** A typed `Signal(a)` stays typed end to end;
   the displaced wiring invariant is checked by debug/safe-build carrier tags that
   compile out of release. *We know this holds when:* the safe-build spec suite
   runs clean with tags asserted, and the tags are absent from release builds.

## Proving Breadth and Depth: the App Suite

The representative apps are not demos; each exists to make one capability fail
loudly if it regresses. The bar for adding an app is **"it exercises an
otherwise-unproven capability,"** never size or visual richness. The maintained
public suite is:

- `spreadsheet-lite` — a formula grid: cell references, precedence, `SUM`
  ranges, error propagation, cycle detection, and dependency-scoped rendering
  over fixed-point arithmetic.
- `data-grid` — 1200 generated rows rendered a page at a time, sortable and
  filterable, with inline editing, selection spanning unrendered rows, and a
  summary aggregating the full dataset. The gallery's performance watch point.
- `dependency-scheduler` — cascading dates through a dependency graph, derived
  slack, critical-path shifts, and cycle reporting.
- `kanban-board` — keyed reorder across containers, WIP limits, and derived
  per-column counts.
- `query-builder` — a recursive AND/OR tree with nesting, negation, and a live
  match count.
- `package-explorer` — routed detail pages with three independently loading
  panels, latest-wins search, and requests cancelled by navigation.
- `support-inbox` — polled server state merged with optimistic sends, unread
  counts that do not re-render the open thread, and rollback on failure.
- `field-notes` — offline-first capture with an outbox that drains on
  reconnect, `Browser.online()` gating, and localStorage as the base of truth.
- `status-page` — visibility-gated polling and a rollup fanning in from several
  independent service checks.
- `flight-search` — the derived-view versus effect-trigger distinction: filters
  refetch, sorting does not.
- `onboarding-wizard` — multi-step validation, plan-dependent options,
  cross-state reducers, a saved draft, and an async submit.
- `availability-picker` — one timezone signal converting every rendered slot,
  with pairwise conflict detection.
- `form-builder` — a designer whose generated form is itself reactive: signals
  composing across two levels.
- `token-editor` — tokens driving live previews and derived WCAG contrast
  validation.
- `loan-comparator` — an expensive derived value memoised per scenario and read
  by seven sinks, with a cross-scenario break-even point.
- `split-the-bill` — a balance diamond fanning into a minimal settlement plan in
  exact integer cents.
- `recipe-scaler` — one input fanning out to dozens of derived leaves with no
  structural work.
- `markdown-editor` — one source string feeding four independently derived
  views, with markdown rendered as ordinary `Elem` structure.
- `log-viewer` — high-frequency appends where only the tail mutates.
- `pomodoro-tracker` — interval-derived elapsed time, per-project rollups, and
  localStorage restore.

- `conduit` — the RealWorld spec app and platform evidence instrument: app-code
  hash routing across nine route shapes with per-route titles, deep links,
  Back/Forward coverage, feeds,
  sessions, profiles, markdown articles, comments, favorites, follows, and
  server-confirmed write paths.

Focused internal fixtures carry narrow canaries that should not become broad
catalog pressure: duplicate-key diagnostics, task
superseding and UTF-8 task ownership, browser environment commands/sources,
initial-aware signal-change commands, markdown-to-`Elem` structure and link
safety, controlled input reconciliation, textarea, number, select, radio,
checkbox, submit/reset default actions, optional text attrs, validation
patterns, callable-allocation signal identity, keyboard events, custom DOM
events, cross-capability `Signal.combine`, asynchronous state writes,
cross-state reducer reads, metric semantics, generated large-`Ui.each`
scaling, `Signal.select` membership under large N, recursive `Ui.switch`
structure, component inputs/children/scope, subscription start/stop by scope,
widget attach/message/event/detach, and per-error-class diagnostic text.

Host tests cover topological rank ordering, diamond deduplication, confined
erasure through carrier tags, retained closure lifecycle accounting, dirty cache
pruning, and local structural splicing.

Keep each app minimal: the smallest structure that exercises the capability and
the tightest `expect_metric_delta` assertions that prove the scaling property.
Avoid catalog-style fixtures and avoid re-proving already-green identity
behavior.

**Foundation coverage the suite must carry.** Proving behavior is not enough; the
suite must also assert *work*, so a regression to O(N) work fails the build rather
than passing silently:

- A **generated large-N `Ui.each` app** (the scaling fixture). N is a build
  parameter; the rows are generated programmatically, not handwritten. It is the
  one place where large N is allowed, precisely because it is systematic rather
  than a catalog. Its specs assert the budget for single-row update, append,
  remove, filter, and reorder — including the `active_graph_records_rebuilt`,
  `stream_nodes_scanned`, `each_key_compares`, and per-event allocation counters.
- **Work assertions on structural and lifecycle paths.** `kanban-board`
  cross-container reorder, `data-grid` row create/remove, `field-notes`
  cleanup, `task-latest-wins` stale-result handling, and the generated
  `large-each-*` fixtures carry `expect_metric_delta` blocks that bound work and
  prove no retained closure, allocation, row, or stale-task leak across the
  relevant cycle.
- **Real-event and async fanout assertions in maintained apps** should keep
  bounding `derived_calls_into_roc`, task lifecycle metrics,
  and row counters so shared-signal amplification is pinned on the live path.
- **A reorder host test at large N** that fails if reorder degrades from
  moves-only to whole-site re-collect.
- **`Rows` transition model and fault tests** compare every public edit sequence
  against a simple reference list, including lineage forks, stale siblings,
  duplicate keys, invalid ranges, remove/reinsert slot preservation, key-changing
  sets, delayed row reads, nested structure, and stale slot handles. A matching
  parent must increment only `rows_delta_batches`; a valid stale sibling must
  increment `rows_snapshot_batches` and scan exactly N snapshot items; its next
  direct edit must resume delta processing. Exhaustive host-allocation fault
  placement preserves the previous generation and publishes nothing. A
  model-based fuzz target crosses those sequences with fault positions and must
  be mutation-tested against a deliberately broken transition implementation.
- **Long-session `Rows` plateaus** warm a 10,000-row site, then run at least
  1,000 fixed-size update, move, remove/reinsert, and nested-scope cycles. Live
  allocations, retained bytes, table capacities, and Wasm pages must plateau;
  same-key updates must report no snapshot scan, untouched-key projection or
  builder calls, order-link touches, DOM moves, or global graph work.

## Open Questions

These are genuine unknowns that require inspecting compiler behavior, generated
ABI, layout rules, or browser constraints.

- **Controlled inputs / focus / IME / selection.** Whether the guarded
  `SetValue` rule plus explicit descriptors is sufficient for focused masking
  and selection-preserving normalization, or whether a first-class
  input-reconciliation descriptor is required, is a browser-behaviour question
  answered by measurement against real IME and selection APIs.
- **Animation / high-frequency continuous values.** A push graph driven by
  discrete updates may need a dedicated `interval`-driven path for smooth
  animation; whether a rAF-coalescing layer buys anything is a measurement.
- **Many-widget embedding cost.** The browser model is one Wasm instance per
  active mount. Whether many small widgets need an explicit same-instance
  mount-handle model is a measurement, not a default design assumption.
- **Recompute granularity.** Whether batching of in-host recompute buys
  anything is a measurement, not a fixed decision.
- **Widget payload breadth.** Whether the scalar/record boundary vocabulary is
  enough for real third-party widgets (charts, editors) or whether a
  byte-array boundary value earns its place is answered by the interop canary,
  not decided in advance.
- **Native vs. browser render-surface parity.** Whether the native spec runner
  should consume the same command-buffer wire format the browser does, to keep a
  single render surface rather than two emit paths behind one command enum.
