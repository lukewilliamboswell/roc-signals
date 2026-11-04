# Phase 2 "each in D" (2026-11-04, nightly 2026-11-03-34bd006)
Unified D engine with keyed each over typed columns; jfb, canary, nested-each run.
Paired Node (ms median) current / Phase 1 / unified: create_10k 1,420 / 56.5 / 57.5 (4.0%);
clear_10k 853 / 0.93 / 1.10 (0.13%); update_10k 84.5 / 2.49 / 3.30; remove_1k 34.2 / 0.171 / 0.432.
Speed gate PASS. Wasm pages flat (227).
FAIL: sparse ops copy touched columns (~32 B/row/column; update-one 9 allocs but 961 KB
at 10k). Minimal engine app copies 80 KB/click under speed/size, 412 B under dev.
Not minimised; see compiler-defect-draft.md, repro/.
FAIL/RISK: Wasm size jfb 532 KB speed / 413 KB size (Phase 1 97 KB); ~70 KB per state
type, ~170 KB per each site; each_fixed boundary regressed (1,137 KB; action lenses ~440 KB).
Mutations: prune removal, swap-order, extra copy all caught. Details in results/.
