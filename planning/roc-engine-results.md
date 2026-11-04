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

## Phase 5: payloads, effect channel, Conduit (2026-11-05; evidence p5/)

Payloads: the Wasm host stages a Roc `List(U8)` per event (`payload_reserve`; capacity is stored
shifted left by one, else short values read as seamless slices and trap). `runtime.mjs` caught up
with the command stream (event names on LISTEN/template holes, row hole targets resolved at INST,
"" removes an attribute, value/checked/boolean attributes as live control state, `:prevent` event
policy, SVG namespace). Real-Chrome replays with typed input: form-builder 12/13 (a number input
sanitizes "2x"), kanban 10/10, data-grid 9/9, markdown 11/11; jfb keyed checks pass.

Effect channel (pure engine): `watch` / `on_change` sites turn value changes into requests.
Commands (history push/replace, title, storage set/remove) are emitted. Awaited requests (HTTP,
storage read, timer, interval, popstate) get instance-wide ids, a bounded in-flight table
(refusal is a typed `Refused` follow-up), and results enter as events through the same turn and
Changed pass. Disposal follows design.md: subscriptions, intervals and timers are cancelled;
admitted HTTP/storage reads reparent to the surviving `when`/`switch`/`each` that disposed them
and run their reaction there (writes to retired states skipped and counted, survivors commit).
Unknown, delivered, stopped or purged ids are dropped and counted. A model-oracle fuzz target
(apps/effects, bound 5) passes ~85k programs per minute with exact allocation baselines; of 9
mutations, 8 are caught by the model (incl. cancel-on-dispose), the ninth by the allocation baseline.

Conduit: full port (apps/conduit; builtin Json works). Specs 24/25 natively and 24/25 in Chrome
(manual effects); an automatic-mode journey against the deterministic RealWorld backend passes.
login-422 expects a second, identical feed request that the original engine admits incidentally
("currently admits two feed generations"); the port does not reproduce it. Native timing vs the
current engine: mount 68 vs 610 us; feed render 236 us vs ~5.4 ms (N=20), 2.2 vs ~50 ms (N=200);
tag-click 0.60 vs 17.2 ms (N=200). Sparse allocations flat for favorite (15-16) and its response
(47) at 10x data.

Open blockers (not code size): controlled-input focus/IME deferral; no focus commands or
blur/focus events, static `:prevent` only; HTTP results carry status and body only, no timeout
policy; contract errors trap the instance (no containment/remount); reparented orphans retain a
snapshot of the retired layers until their result arrives (bounded by the in-flight cap).
Compiler: roc-lang/roc#12851 (undeclared type in a `provides` annotation segfaults in monotype).

### Phase 5b: blockers resolved (2026-11-05)

- Controlled inputs (design.md "Controlled inputs"): an equal value is a no-op, so caret and
  selection stay. A differing value is deferred while the control is focused or composing and
  applied on blur, unless a later input echo matched it. design.md says blur, not compositionend.
  Chrome tests cover typing, deleting and replacing mid-text and a CDP IME composition. Two
  runtime mutations are caught.
- Focus: `Engine.ref(name)` plus Focus/Blur/SelectText effects, resolved at the end of the turn into
  `18 FOCUS op node`; a missing reference is counted stale. App `focus`/`blur` events carry the
  value. Native and Chrome tests. Found and fixed: an element with several handlers routed every
  event to its last handler.
- HTTP: results carry headers; `timeout_ms` per request (capped at 600 s) yields a typed `Timeout`.
  The timer is cleared on completion, failure or cancel. The model checks the wire round trip;
  uncapped timeouts, a lost header value and Timeout decoded as Network are all caught.
- Containment (design.md failure rules): a Roc crash, failed expect or allocation failure poisons
  the instance. It records a classified, bounded diagnostic (contract, resource_limit,
  out_of_memory, app_crash, expect_failed), e.g. `contract: duplicate key "r0" in each at site
  /3/0`, discards staged commands and refuses re-entry. The runtime reports the fault, detaches
  listeners and effects, keeps the last DOM and recovers with a fresh instance. Covered by a
  Chrome test.
- Conduit login-422 (spec fidelity): the original navigated first and its storage-backed session
  flipped a turn later, so home fetched the feed anonymously, then again with the token. The port
  reproduces that request order. Conduit now passes 25/25 natively and in Chrome.
- Soak, native: every app's target has an explorer-driven random walk over the live DOM (leak-checked)
  and seeded examples of 10k events. Markdown and Conduit run them as 5 x 2k, because one 10k
  walk through the DOM oracle exceeds the per-input timeout. All runs are leak-free. A round trip
  replayed 12 times on the engine alone gives flat live allocations after one warm-up cycle:
  form 149, kanban 235, grid 73, markdown 656.
- Soak, Chrome: 3,000 random events per app with no fault. Then 30 round trips: pages are flat
  (139-144) and live allocations exactly flat for the four apps; Conduit, with async effects,
  jitters 942/943 with no growth.
  Found while soaking: `resource_limit` at 4,095 live each sites (12-bit site ids in node ids);
  resolved in Phase 5c below.
  The form bench with ~65k fields hits it. This is a real scale limit.
- Conduit in Chrome (eager Wasm compile, median ms, current vs spike): feed N=200 76.7 vs 17.8;
  tag-click N=200 22.4 vs 3.8; feed N=20 9.2 vs 3.4; mount 3.1 vs 1.9. First paint is slower for
  the spike (62-67 vs 25-26 ms) because it is the larger module.
- Optimised Wasm sizes (gzip of -Oz), spike vs current: form 545 vs 519 KB, kanban 405 vs 483,
  grid 266 vs 482, markdown 939 vs 546, Conduit 1,501 vs 940. Code size is still the main
  blocker (roc-lang/roc#12847, #12848).
  Current-engine finding: its browser storage import misreads keys of 11 bytes or fewer (Roc
  small strings on wasm32).

### Phase 5c: node and site ids without bit-width limits (2026-11-05)

Rows used to get node ids `(site << 20) | slot+1`: at most 4,095 live each sites and 1M rows per
site. Now every element, rows included, takes a dense u32 id from one recycled pool. The routes
table maps the id to a block path or to a row's (site, slot), so event routing is one O(1) lookup
plus the site's path. Each site ids are dense, recycled, and no longer packed into anything. The
only limit left is 2^32 - 2 live nodes, i.e. memory.

Recycled ids can't alias:
- a freed node id has no route, so a stale event drops;
- the runtime drops a queued event whose element left the DOM or whose id was reused;
- a site's rows are forgotten on CLEAR (per-site row sets in the runtime and the DOM oracle).

Results:
- **More than 4,095 each sites:** a test app mounts 5,001 sites (5,000 rows, each with a nested
  each), shrinks to 1,250 rows, then regrows 5,000 with new keys, so sites and ids are recycled.
  Clicks deep in the newest rows route correctly. It passes natively. The old engine crashes with
  `resource_limit: each sites exhausted`. The form app mounts 65,536 fields (65,537 each sites:
  3.36M allocations, 2.19 GB requested).
- **Specs:** all specs pass natively, and the Chrome replays are unchanged (form 12/13, kanban
  10/10, grid 9/9, markdown 11/11, Conduit 25/25, Conduit journey, effect, controls and jfb
  checks). Baselines are re-accepted.
- **Allocations:** 80 of 110 bench steps are unchanged; 30 rise slightly from the routes and
  row-node columns, e.g. data-grid page turns 18 -> 21, kanban filter-one 360 -> 466 at N=400,
  Conduit feed N=200 17,078 -> 17,280, form mount N=200 +2 allocations.
- **A leak found and fixed:** row ids now come from the shared pool, so a disposed static each
  (no DOM removal needed) must still release them. Missing that leaked ids in Conduit, and Chrome
  pages grew from 142 to 159 over 200 round trips while the live allocation count stayed flat.
  - The browser soak now also asserts no growth in live bytes.
  - The native soak replays its round trip 48 times inside measured regions and requires zero net
    live bytes per cycle after warm-up.
  - It catches the leak in a mutant (2,560 bytes at cycle 19). The fix is flat: Conduit stays at
    142 pages and 175,959 bytes.
- **jfb in Chrome** (eager compile, median of 15, old vs new id scheme): create 1k 29.4 vs 29.9 ms,
  create 10k 240.6 vs 248.1 ms (+3%: one pooled id and one route entry per row). The keyed checks
  all pass.
- **Markdown cycle:** the app's append/remove-section trip is not an exact inverse (one more
  trailing newline per trip), so its soak cycle now loads two fixed documents.
