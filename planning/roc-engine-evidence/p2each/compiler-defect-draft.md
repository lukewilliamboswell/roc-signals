# DRAFT (not filed): uniquely owned state captured by a closure is copied on every update under --opt=speed/size, in place under --opt=dev

Compiler: nightly-2026-11-03-34bd006, Linux x86_64, target wasm32 (also native via roc-fuzz).
Likely related: roc-lang/roc#12841 (same symptom: dev in place, speed copies), but here only
ONE closure captures the list.

## Repro (not minimal yet)

`probe/p1/main.roc` on `platform-roc/` (the Phase 2 engine `src/Engine.roc`, ~1,900 lines):
one state holding a 10,000-element `List(U64)`, one button whose handler replaces element 0.

    bash probe.sh p1 speed   ->  click: allocs=7 bytes=80468   (whole list copied every click)
    bash probe.sh p1 size    ->  click: allocs=7 bytes=80468
    bash probe.sh p1 dev     ->  click: allocs=5 bytes=412     (in place)

The engine's state site is representation D: one closure `Inst(|env, msg, tx| ...)` captures
the state value `s`; on `Fire` it moves `s` into an environment record, runs the handler
(`|e| modify(e, f)`, a lens that destructures the record) and rebuilds the closure from the
handler's result. `s` has no other use on that path.

## What did not reproduce standalone (all in place under speed AND dev)

- `repro/one.roc`: single closure capturing a list + config record, rebuilt each update;
  variants with a conditional update and with an app-style reducer that returns its input.
- `repro/two.roc`: environment threaded through and handed back, noop member in the lambda
  set, parent site forwarding to a child list with the replace pattern.
- `repro/three.roc`: closure moves the list into an env record and runs a handler fetched
  from a `List({ mask, run })`.

## Engine-side mutations that did NOT remove the copy (bisect.sh / tools/mut.py)

m1 state value used only on Fire; m2 no refresh after handler; m3 no branching after the
handler; m4 no Err branch in fire_block; m13 handler destructured before running; m14 lens
without destructuring; m15 update without lens indirection; m16 root consumed on every event
path; m20 state site runs the handler itself (no fire_block).

## Second, backend-independent symptom

In the full jfb app the dev backend also copies, at different places (wasm counters,
`benchmarks/js-framework-benchmark/roc-d-keyed/test/wasm_counts.mjs`): select 16 B/row,
update-every-10th 16 KB/row-touched; speed copies ~20 B/row (wasm32) on every sparse op.
Allocation COUNTS stay constant across sizes; requested bytes scale with N.

## Next step to minimise

Delete engine features from the probe's engine copy until the dev/speed difference
disappears (each probe build is ~15 s). Not done in this spike.
