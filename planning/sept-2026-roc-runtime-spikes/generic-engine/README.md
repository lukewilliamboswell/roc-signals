# Generic-engine investigation (temporary, ignored)

## Acceptance criterion

Application code keeps the existing Ui.state / Signal.map / Signal.map2 / Html
API. The platform owns construction, storage, scheduling and disposal. No
application-written graph model, global value union, node IDs, registration or
update loop is acceptable. Per-event view reconstruction is not an alternative.

The generic-column experiment in app.roc does NOT satisfy that criterion. It is
a storage/specialization probe only, not a proposed application API or engine
replacement. Do not promote its app-owned Model/main callbacks into production.

## Debug baseline with unchanged public API

```sh
bash .test-out/generic-engine/same-api/reproduce.sh
```

Uses pinned nightly-2026-09-12-220fd47, a freshly built Zig Debug native host,
and a default (unoptimized) Roc build. The fixture uses the EXISTING Zig engine.
It is not yet connected to an experimental Roc engine.

The native semantic spec passes and establishes:

- Separate counter and two reusable task components with different state types.
- Captured component labels and nested heap-backed strings/lists.
- A task diamond evaluates exactly three derived nodes on toggle, with zero
  active-graph rebuilds and zero scope creation/disposal for that update.
- An equal counter update evaluates zero derived nodes.
- Updating one component leaves its sibling and counter unchanged.
- Disposing and rebuilding one component resets its local state while the
  sibling and counter retain theirs.

Earlier runs against the preexisting optimized host artifacts aborted with
Invalid free. Rebuilding the host as Debug and linking a default Roc build
passes. This does not identify the cause or establish an optimized-build fix.
The positional native invocation without --host-run-spec-json is not a test
result; use the script above, which emits an explicit passed JSON record.

## What the generic storage probe established

platform/Engine.roc specializes a four-node diamond for four independently typed
columns using where equality constraints. Task records -> Str/Bool -> view
records and cart records -> U64/shipping tags -> view records compile and pass
the fixed semantic/teardown checks, including per-row captured closures.

This is fixed topology, not extraction of a general DAG. The original optimized
probe also observed graph-sized allocations on sparse updates. Factoring a
prepare/install path did not eliminate them. A direct platform-fixture control
removed some but not all of those allocations. No compiler cause is established.
New work uses Debug builds; reproduce.sh was changed accordingly. Do not compare
its new output with earlier optimized measurements as a performance comparison.

## The unresolved type boundary

The actual public signature is:

    Ui.state : a, (State(a) -> Elem) -> Elem
        where [a.is_eq : a, a -> Bool]

Its result is a non-generic Elem. Likewise Html.text_s consumes a typed signal
but returns Elem, and containers accept List(Elem). A constraint supplies typed
operations for a concrete specialization; it does not make the different state
and cache types visible in the container's type or synthesize an application-wide
record containing them.

The current implementation packages typed operations into retained capabilities
at these platform combinators. Moving the scheduler into Roc does not by itself
remove this type-hiding requirement. A compatible design still needs a safe
platform-private representation for heterogeneous retained state and closures.
It may consolidate ownership or storage without eliminating every allocation,
but the generic-column test has not demonstrated that representation.

design.md remains unchanged and still specifies the Zig runtime. These files
are evidence for exploring an alternative, not an undocumented architecture
change. No replacement runtime has been implemented in the unchanged-API path.
