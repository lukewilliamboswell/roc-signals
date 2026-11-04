# Packed Roc runtime experiment

Run from the repository root:

```sh
bash .test-out/roc-owned/native.sh
bash .test-out/roc-packed/native.sh
/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc test .test-out/roc-packed/platform/Links.roc
/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc test .test-out/roc-packed/platform/Small.roc
```

Both native runs explicitly use the pinned nightly, Roc --opt=dev
--specialize=yes and Zig Debug. Host request accounting uses libc allocation.
Realloc allocates and copies; these are representation counts, not speed claims.

IMPORTANT CORRECTION: the earlier Wasm scripts omitted --opt, incorrectly assumed
to mean dev. This nightly's roc build defaults to speed. Those earlier numbers
were mixed-mode, not Debug-only. Scripts now explicitly select dev. That exposes
invalid Wasm in both baseline and changed runtimes: Node rejects an extra stack
value at fallthrough before execution. Native dev is the working evidence here;
the Wasm compiler failure is not yet minimized or attributed to an upstream issue.

## Changes

- Node dependents and scope ownership use integer chains in one flat Links table.
  Owners no longer retain separate heap lists for nodes, visuals, bindings and
  child scopes. Entries preserve insertion order.
- One sink fits inline in its node record; multiple sinks use ordinary List
  overflow. An earlier four-inline-entry trial enlarged records unnecessarily
  and was replaced by the compact representation.
- Signal.map/map2 capture only input capabilities, not entire Signal records.
  This releases three input-descriptor allocations per TaskPanel after ingestion.
- Equality callbacks, text/bool readers and event reducers no longer have
  explicit Box wrappers in their private handle fields. This alone produced
  no allocation-count change on the native dev fixture. Removing syntax is not
  evidence that closure allocation or upstream erasure disappeared.
- Public app code is unchanged, including the separately defined Task record
  containing strings and a nested list. No app-owned graph/model/value union,
  serialization, arena allocator or host value registry was introduced.

## Native Debug/dev results

| Retained allocations after mount | 10 rows | 100 rows | 1000 rows |
| --- | ---: | ---: | ---: |
| Baseline | 342 | 3222 | 32022 |
| Packed storage and narrower captures | 236 | 2216 | 22016 |

The per-row slope falls from 32 to 22 actual live allocation requests, not merely
fewer allocator calls hidden behind an arena. At 1000 rows, mounted requested
bytes fall from 3,688,358 to 3,562,494. Capacity after clear increases from
1,396,632 to 2,070,824 bytes: the flat table retains its capacity.

At every tested size, a sparse row update runs three derived callbacks, updates
one text node, and requests 25 allocations / 2432 bytes. Clear requests seven
allocations / 667 bytes and frees 228 / 2208 / 22008 allocations respectively.
Sixteen allocation requests remain after clear. Root teardown releases them with
no new allocations and leaves zero live requests/bytes.

The native runner enforces retained-allocation, sparse-update and clear budgets.
The unchanged small fixture also passes counter equality pruning, independent
components, conditional disposal/recreation, independently executable saved
snapshots, nested-value/capturing-callback ownership and zero-live teardown.
Its finish deliberately executes the saved snapshot before releasing it, so its
finish allocation count is not a pure disposal measurement.

## Still open

This does NOT eliminate all per-component heap objects. Cached heterogeneous
getters, capabilities, evaluator closures and app-owned variable-size values
remain. The next representation experiment must remove upstream erasure, not
merely erase Box syntax from individual callback fields.

Construction is still strongly superlinear in requested bytes (~255 MB for 1000
rows here). Links and node/scope/visual slots remain append-only; no long-session
plateau is claimed. Cross-scope detachment remains incomplete. Single-sink inline
storage has an allocating overflow path. These are local experiment limitations,
not changes to production contracts.

The existing descriptor subset and headless rendered-text harness do not establish
general keyed reconciliation, browser publication, effects or native GUI behavior.
design.md remains unchanged and still mandates the Zig engine; this ignored spike
deliberately tests the user's alternative architecture.
