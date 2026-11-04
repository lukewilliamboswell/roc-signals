# Phase 3 column-copy defect (2026-11-04, nightly 2026-11-03-34bd006)
Filed roc-lang/roc#12846 (+ second shape in comment). Captured record in a recursive
closure is treated as borrowed under optimized ownership inference; refcount 2 at
List.replace -> makeUnique copy. dev/interpreter 0 allocs, speed/size 1000 per 1000 calls.
Cascades: one borrowed site copies children list, then every list below copies.
Workaround (engine-workaround.diff): split fire_block per routing case; wrap state_inst
captures in Held(...); rebuild each site before row handler; bounds check + ?? crash.
Native bytes 1k/10k/100k after: update-one 304/232/232 (was 97K/961K/9.6M); swap
304/232/232; remove 976/904/904. Wasm jfb speed+size: update-one 558 B, select 796,
swap 416, remove 864, all flat. All 8 fuzz examples pass (baseline not re-accepted).
Open: native select still 32 B/row; dev backend copies elsewhere (~400 KB at 10k);
unfiled runtime panic with top-level polymorphic record of closures (nat/r2.roc).
