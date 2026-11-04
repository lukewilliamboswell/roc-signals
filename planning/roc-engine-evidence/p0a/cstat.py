import csv, sys, statistics, collections
rows = collections.OrderedDict()
for r in csv.DictReader(l for l in open(sys.argv[1]) if not l.startswith("case,") or True):
    if r.get("case") in (None, "case"):
        continue
    d = int(r["dispatch_roc_ns"]) + int(r["dispatch_apply_ns"])
    rows.setdefault(r["case"], []).append((d, int(r["dispatch_apply_ns"]), int(r["dispatch_roc_ns"])))
for k, v in rows.items():
    t = [x[0] / 1e6 for x in v]
    a = [x[1] / 1e6 for x in v]
    print(f'{k:20} n={len(v)} dispatch median={statistics.median(t):9.3f} ms min={min(t):9.3f} max={max(t):9.3f} | apply median={statistics.median(a):9.3f} ms')
