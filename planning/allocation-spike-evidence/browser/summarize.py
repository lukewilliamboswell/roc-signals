"""Print each framework's median total per benchmark and its ratio to Solid."""
import json, pathlib, statistics, sys
d = {}
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    j = json.loads(p.read_text())
    v = j.get("values", {}).get("total", {})
    xs = v.get("values") if isinstance(v, dict) else None
    if not xs:
        continue
    d.setdefault(j["benchmark"], {})[j["framework"]] = statistics.median(xs)
for b in sorted(d):
    row = d[b]
    solid = next((x for k, x in row.items() if k.startswith("solid-") or k == "solid"), None)
    print(b)
    for k in sorted(row):
        ratio = f"{row[k] / solid:.2f}x" if solid else "n/a"
        print(f"  {k:<40} {row[k]:>9.1f} ms  {ratio}")
