# Phase 2 code-size spike (2026-11-04, nightly 2026-11-03-34bd006). PASS with API change

Cause of D's 17.7 KB/component: each component's closures carry the caller's nested
In(...) ctx, so lambda sets are per component; engine fns (mount_elem 55x40 KB, call,
state_inst, Val.map) are re-specialised per component and LLVM inlines freely.
Context-free core (R1) did not help.

Fix (r2dnb/Engine.roc): Engine.component(prop, body) with fixed env P := { prop : Str },
monomorphic body fn Val(P, Str) -> Elem(P); no nominal Body wrapper.

| Variant | per component native | wasm32 -Oz | gzip |
|---|---|---|---|
| current engine | ~4.1 KB | n/a | n/a |
| D | 17.7 KB | 6.3 KB | 1.37 KB |
| R2 (R1+boundary+nominal Body) | 2.55 KB | 2.26 KB | 0.14 KB |
| R2dnb | 1.05 KB | 0.95 KB | 0.11 KB |

R2dnb runtime, 2,000 mounted: mount 2.81 ms, sparse 19.3 us, swap 0.77 ms (D same
session 8.46 / 21.4 / 2.38). vs current at 200/800: mount 6-8%, sparse 14-16%, swap 3.5-6%.
Allocs at 2,000: mount 20,026; sparse 13 (6.5 KB, depth-bound); swap 5,007.
Build at 2,500 components: 41 s (D 7m51s).

Open: ~130-145 KB native fixed cost per distinct state type (~0.8 MB fixed Wasm at 50
components). Needed: non-Str props, callback props for outer-state updates.
--specialize=no unusable (18-49x slower). Numbers in results.txt.
