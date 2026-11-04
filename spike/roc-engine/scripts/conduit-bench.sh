#!/bin/bash
# conduit-bench.sh -- Conduit browser timing, spike vs current engine, N=20 and
# N=200, RUNS fresh pages each (default 7), one flock'd batch per engine x N.
# JS_FLAGS=--no-wasm-lazy-compilation measures with eager Wasm compilation.
# Needs: scripts/wbuild.sh conduit ($P/wb-conduit/app.wasm) and
# scripts/cursize.sh conduit, then the bench variant $P/cur/conduit-bench-wasm:
# the same Conduit with Session.jwt_key = "conduit.jwt.token" (the current
# browser storage import misreads small-string keys), stack-checked.
. "$(dirname "$0")/env.sh"
RUNS=${RUNS:-7}
OUT=$P/results/browser-timing-conduit${JS_FLAGS:+-eager}.jsonl
: > $OUT
for N in 20 200; do
  for E in spike current; do
    W=$P/wb-conduit/app.wasm; [ $E = current ] && W=$P/cur/conduit-bench-wasm/app.checked.wasm
    flock -w 3600 $LOCK env NODE_PATH=$PUPPETEER_NODE_PATH timeout 1200 node $R/browser/conduit-bench.mjs $E $W $N $RUNS >> $OUT || echo "bench $E n=$N failed" >&2
  done
done
python3 - $OUT <<'PY'
import json, sys, statistics, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
steps = ["firstPaint", "mount", "tags", "feed", "favorite", "favorite-response", "tag-click"]
by = collections.defaultdict(list)
for r in rows: by[(r["n"], r["engine"])].append(r)
print("# Conduit in headless Chrome 153: median ms over %s fresh pages (min-max)" % len(rows and by[next(iter(by))]))
print("%-6s %-18s %22s %22s %7s" % ("N", "step", "current", "spike", "spike%"))
for n in sorted({k[0] for k in by}):
    for s in steps:
        c = [r[s] for r in by[(n, "current")]]; p = [r[s] for r in by[(n, "spike")]]
        if not c or not p: continue
        mc, mp = statistics.median(c), statistics.median(p)
        print("%-6d %-18s %10.2f (%5.1f-%6.1f) %10.2f (%5.1f-%6.1f) %6.1f%%" % (n, s, mc, min(c), max(c), mp, min(p), max(p), 100 * mp / mc if mc else 0))
for k, rs in sorted(by.items()):
    print("checks", k, rs[0]["check"])
PY
