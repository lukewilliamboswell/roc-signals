# Phase 1: Roc engine browser slice (2026-11-04, nightly 2026-11-03-34bd006). CONTINUE

Sources: platform-roc/ (Engine.roc, main.roc, host/host.zig, runtime.mjs) and
roc-engine-keyed/ (jfb adapter, verifier, paired Node + headless Chrome harnesses).
Engine is Phase 0a static composition (Both/EachSite), low-level Engine API, not the
0b/1b API. Results in results/, scripts in scripts/.

## Paired Node + DOM double (per-case process, alternating, ms median)
| Case | Current | New | % |
|---|---|---|---|
| create_1k | 119.8 | 3.40 | 2.8 |
| replace_1k | 184.7 | 1.38 | 0.7 |
| update_10k | 75.5 | 1.89 | 2.5 |
| select_1k | 0.299 | 0.090 | 30 |
| swap_1k | 39.4 | 0.225 | 0.6 |
| remove_1k | 33.3 | 0.149 | 0.4 |
| create_10k | 1,217 | 46.6 | 3.8 |
| append_1k_to_10k | 354.6 | 1.72 | 0.5 |
| clear_10k | 454.1 | 0.546 | 0.1 |

## Headless Chrome 153 script time (ms median)
create_1k 67.4 vs 3.2; create_10k 1,305 vs 38.3 (2.9%); clear_10k 364.7 vs 19.9;
update_10k 40.6 vs 4.4; append 126 vs 2.4. With layout: create_10k 1,489 vs 297.
New create_10k split: Wasm 5.1 ms (13%), JS decode 2.7 ms, DOM ~30.5 ms (80%).
Current create_10k: 1,065 of 1,305 ms is Wasm.

## Memory and size
Wasm pages mount / after create-10k / after clear / after 6 runlots cycles:
current 141 / 11,926 / 13,000 / 16,366; new 135 / 211 / 211 / 212.
app.wasm 97,222 B (28,717 gzip) vs current 5,522,024 B (1,254,629 gzip), both --opt=speed.

## Allocations (roc-fuzz exact baseline p1-engine_baseline.json)
update-one/select/remove 1 alloc at 1k/10k/100k; swap 0; create 55/354/3,219.
Wasm adds +1 per call (Box(State) rebox) and heap labels > 11 bytes (wasm32 small-str
limit), giving ~1 alloc/row on create. Two new mutations caught. 60 s exploration passed.

## Caveats
Current rows carry extra data-row-id/testid/aria-label strings; current artifact has
stack-check instrumentation. Heterogeneous tree not measured here (see p1b).
Single-process harness hung in futex after replace_1k (current engine Wasm memories
~1 GB each, swap full); fixed by one process per case.

## Compiler notes (not filed)
roc check SIGSEGV in monotype with recursive structural alias in type module + platform
requires needing where methods (not minimized). No way to put where constraints on
platform requires type vars (limitation; workaround Engine.program bound in the app).
