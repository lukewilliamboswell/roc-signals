"""Summarize official js-framework-benchmark result JSON into a Markdown table.

Usage: python3 -I summarize.py RESULTS_DIR > summary.md
CPU: median and mean of `total` (ms), with ratios to solid and to roc-signals (median).
Weighted geometric mean follows webdriver-ts-results/src/Common.ts: factor = median / min
over the frameworks shown, weights per benchmark 01..09; also reported with Solid as the base.
"""
import json, math, pathlib, sys

W = [0.64280248137063, 0.5607178150466176, 0.5643800750716564, 0.1925635870170522, 0.13200612879341714,
     0.5277091212292658, 0.5644449600965534, 0.5508359820582848, 0.4225836631419211]
ORDER = ["solid", "roc-signals", "roc-engine-p1", "roc-d-each", "roc-d-p3copy", "roc-d-p3m"]
d = {}
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    j = json.loads(p.read_text())
    fw = j["framework"].split("-v")[0]
    d.setdefault(j["type"], {}).setdefault(j["benchmark"], {})[fw] = j["values"]
fws = [f for f in ORDER if any(f in b for t in d.values() for b in t.values())]

def short(f):
    return f.replace("roc-", "")

cpu = d.get("cpu", {})
bks = sorted(cpu)
print("## CPU (ms, `total`; median / mean; n per run in the JSON)\n")
print("| benchmark | " + " | ".join(fws) + " |")
print("|---|" + "---|" * len(fws))
for b in bks:
    cells = []
    for f in fws:
        v = cpu[b].get(f, {}).get("total")
        cells.append(f"{v['median']:.1f} / {v['mean']:.1f}" if v else "-")
    print(f"| {b} | " + " | ".join(cells) + " |")

def gm(base_fn):
    out = {}
    for f in fws:
        s = 0.0; wsum = 0.0
        for i, b in enumerate(bks):
            v = cpu[b].get(f, {}).get("total")
            base = base_fn(b)
            if v and base:
                s += W[i] * math.log(v["median"] / base); wsum += W[i]
        out[f] = math.exp(s / sum(W)) if wsum else float("nan")
    return out

gmin = gm(lambda b: min(cpu[b][f]["total"]["median"] for f in fws if f in cpu[b]))
gsol = gm(lambda b: cpu[b].get("solid", {}).get("total", {}).get("median"))
print("| **weighted geomean (official, vs fastest shown)** | " + " | ".join(f"{gmin[f]:.2f}" for f in fws) + " |")
print("| **weighted geomean vs Solid** | " + " | ".join(f"{gsol[f]:.2f}" for f in fws) + " |")

print("\n## CPU ratios (median total)\n")
roc = [f for f in fws if f not in ("solid",)]
hdr = []
for f in roc:
    hdr.append(f"{short(f)}/solid")
    if f != "roc-signals":
        hdr.append(f"{short(f)}/current")
print("| benchmark | " + " | ".join(hdr) + " |")
print("|---|" + "---|" * len(hdr))
for b in bks:
    def m(f):
        v = cpu[b].get(f, {}).get("total"); return v["median"] if v else None
    cells = []
    for f in roc:
        for base in (["solid"] if f == "roc-signals" else ["solid", "roc-signals"]):
            a, c = m(f), m(base)
            cells.append(f"{a / c:.2f}x" if a and c else "-")
    print(f"| {b} | " + " | ".join(cells) + " |")

for t, title, key in (("memory", "Memory (MB)", "DEFAULT"), ("startup", "Startup", None), ("size", "Size", None)):
    sec = d.get(t, {})
    if not sec:
        continue
    print(f"\n## {title}\n")
    print("| benchmark | " + " | ".join(fws) + " |")
    print("|---|" + "---|" * len(fws))
    for b in sorted(sec):
        keys = sorted({k for f in fws for k in sec[b].get(f, {})})
        for k in keys:
            cells = []
            for f in fws:
                v = sec[b].get(f, {}).get(k)
                cells.append(f"{v['median']:.2f}" if v else "-")
            print(f"| {b} {'' if k == 'DEFAULT' else k} | " + " | ".join(cells) + " |")
