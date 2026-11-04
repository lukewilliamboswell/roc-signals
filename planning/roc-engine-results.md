# Roc-owned engine spike: consolidated results (2026-11-04)

Nightly 2026-11-03-34bd006. Plan: planning/roc-engine-spike.md. Evidence:
planning/roc-engine-evidence/{p0a,p0b,p1,p1b,p2size,p2each,p3copy,p3size}.
Nothing committed; design.md untouched.

## Verdict
The speed hypothesis is validated: a pure-Roc engine with typed per-site storage runs
the jfb workload at 1-4% of the current engine and the mixed-component tree at 3-16%.
Remaining blockers are Roc compiler behaviours (in-place ownership, code size), not
the architecture.

Official js-framework-benchmark (headless Chrome 153, default iterations, 2026-11-04;
evidence jfb-official/): weighted geomean vs Solid 1.9.3: unified D+each 0.82,
Phase 1 static 0.90, p3copy 1.01, p3m 1.00, current roc-signals 2.98. create10k
d-each 362 ms vs Solid 422 vs current 1,615. All pass isKeyed. Memory: Roc engines
~9-11 MB (Wasm linear memory baseline) vs Solid 0.6-2.7 MB vs current 88-115 MB.
Size compressed: Solid 4.5 KB, p1 25.8 KB, p3m 75 KB, d-each 107 KB, current 515 KB.
First paint: Solid 37 ms, p1 112 ms, p3m 370 ms, d-each 954 ms, current 2,971 ms.

## Speed
jfb paired Node (ms median), current / Phase 1 static engine / unified D+each:
create_10k 1,420 / 56.5 / 57.5; clear_10k 853 / 0.93 / 1.10; update_10k 84.5 / 2.49 / 3.30.
Headless Chrome create_10k script: 1,305 vs 38.3 ms (Phase 1). Wasm is 13% of that;
DOM is ~80%. Further gains are DOM tactics, not Roc.
Wasm memory flat at ~212-227 pages vs current 16,366 after 6 runlots cycles.

Mixed tree (no each), native:
| Mounted | Current mount/sparse/swap | R2dnb mount/sparse/swap |
|---|---|---|
| 200 | 2.95 ms / 33 us / 1.21 ms | 0.224 ms / 5.3 us / 0.073 ms |
| 800 | 14.1 ms / 51 us / 5.0 ms | 0.76-0.97 ms / 6-8 us / 0.23-0.29 ms |
| 2,000 | 54 ms / 85 us / 18 ms (dev build; speed build >90 min) | 2.81 ms / 19 us / 0.77 ms |

## Representation and API
D: one closure per site, Val with layer masks, handlers ctx -> ctx, lens state handles
with explicit lift/lift_row. Component boundary with fixed env (Engine.component) is
required for code size. Canary and nested-each run with exact counts.

## Blockers and status
1. In-place updates: roc-lang/roc#12846 (captured record borrowed under optimized
   ownership inference) and #12841 (two closures sharing a capture). Engine workaround
   (p3copy) makes update/swap/remove bytes flat at 1k/10k/100k; native select still
   32 B/row; dev backend copies elsewhere.
2. Code size: jfb Wasm 97 KB (static Phase 1) / 463 KB (D+each) / 297 KB (best p3m).
   Per component ~1 KB with boundary; per state type ~14-16 KB; per each site ~62 KB.
   Causes: borrowed-call double specialisation (~30%) and inlinehint on every proc.
   Filed upstream as roc-lang/roc#12847 (borrowed-call duplicate) and #12848 (inlinehint, no minsize/noinline).
3. Compile time: D at 2,500 components 41 s with boundary (current engine >90 min).

## Not done
Conduit port (needs task/effect channel, history routing, storage) and long-session
gates (Phase 2 breadth). Callback props, non-Str props, memoised derivations.

## Real-app ports (evidence p4apps/)
form-builder 13/13, kanban-board 10/10, data-grid 9/9, markdown-editor 11/11 original
specs pass (replayed through Engine.event with a decoded-DOM oracle; 4 engine mutations
caught). Conduit not ported. Native mount 1-6% of current, events 0.1-15%. Sparse engine
allocs flat across 10x data (form edit 9 allocs / 2,621 B at 20 and 200 fields).
Wasm -Oz size vs current: form 89%, kanban 72%, grid 48%, markdown 144%; per-app Roc code
several times larger than current (current includes ~1.1 MB fixed host). Code size is the
blocker for real apps. Engine added derive, component(prop, sink, body), switch, input
payloads, static read masks, root settle. Wasm host does not yet marshal event payloads.
Authoring: 82-93% of original view code; explicit lift/lift_row; hidden copy traps
(keep_if on shared lists, large state not outermost, deriving projections of state).
