"""inl.py BINARY [SRCDIR] [topn] -- exclusive code bytes per Roc source function, using the
DWARF inline tree (innermost inlined origin owns the bytes). Lambdas are reported as
`\\ in <enclosing top-level fn>` using SRCDIR/<File>.roc to map decl lines to definitions.
Also prints the number of distinct concrete/inlined instances (copies)."""
import sys, subprocess, re, collections, os
binp = sys.argv[1]; srcdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(binp) or "."
topn = int(sys.argv[3]) if len(sys.argv) > 3 else 50
dw = subprocess.run(["llvm-dwarfdump-18", "--debug-info", binp], capture_output=True, text=True).stdout.splitlines()
defs = {}
def enclosing(f, line):
    if f not in defs:
        p = os.path.join(srcdir, f + ".roc"); lst = []
        if os.path.exists(p):
            for i, l in enumerate(open(p), 1):
                m = re.match(r"^\t(?:\t)?([a-z_][a-z0-9_!]*) = ", l)
                if m and l.startswith("\t") and not l.startswith("\t\t\t"): lst.append((i, m.group(1)))
        defs[f] = lst
    best = "?"
    for i, n in defs[f]:
        if i <= line: best = n
        else: break
    return best
dies = []  # (off, depth, tag, attrs)
cur = None; inranges = False
for line in dw:
    m = re.match(r"^0x([0-9a-f]+):(\s+)(DW_TAG_\w+)", line)
    if m:
        cur = {"off": int(m.group(1), 16), "depth": len(m.group(2)), "tag": m.group(3), "ranges": []}
        dies.append(cur); inranges = False; continue
    if cur is None: continue
    s = line.strip()
    if inranges:
        mm = re.match(r"\[0x([0-9a-f]+), 0x([0-9a-f]+)\)", s)
        if mm: cur["ranges"].append((int(mm.group(1), 16), int(mm.group(2), 16)))
        if s.endswith("))") or not mm: inranges = False
        continue
    mm = re.match(r"DW_AT_(\w+)\s+\((.*)$", s)
    if not mm: continue
    k, v = mm.group(1), mm.group(2)
    if k == "ranges": inranges = not v.endswith(")") or True
    elif k == "low_pc": cur["low"] = int(v.split(")")[0], 16)
    elif k == "high_pc": cur["high"] = v.split(")")[0]
    elif k in ("abstract_origin", "specification"): cur["origin"] = int(v.split()[0], 16)
    elif k == "name": cur["name"] = v.rstrip(")").strip('"')
    elif k == "decl_file": cur["file"] = v.rstrip(")").strip('"').split("/")[-1]
    elif k == "decl_line": cur["line"] = int(v.rstrip(")"))
for d in dies:
    if "low" in d and "high" in d and not d["ranges"]:
        h = d["high"]; hv = int(h, 16)
        d["ranges"] = [(d["low"], hv if hv > d["low"] else d["low"] + hv)]
byoff = {d["off"]: d for d in dies}
def ident(d):
    o = d
    seen = 0
    while "origin" in o and o["origin"] in byoff and seen < 5:
        o = byoff[o["origin"]]; seen += 1
    n = o.get("name", "?"); f = o.get("file", "?"); l = o.get("line", 0)
    if n.startswith("roc__"):
        n = "\\ in " + enclosing(f, l)
    return (f, n)
def size(rs):
    rs = sorted(rs); tot = 0; ce = -1
    for a, b in rs:
        if b <= ce: continue
        a = max(a, ce); tot += b - a; ce = b
    return tot
excl = collections.Counter(); copies = collections.Counter(); totsz = 0
stack = []
for i, d in enumerate(dies):
    if d["tag"] not in ("DW_TAG_subprogram", "DW_TAG_inlined_subroutine") or not d["ranges"]: continue
    # children: following dies at greater depth until depth <= d.depth
    kids = []
    for e in dies[i+1:]:
        if e["depth"] <= d["depth"]: break
        if e["tag"] == "DW_TAG_inlined_subroutine" and e["ranges"]:
            # direct inline children only: skip those nested within another inline child
            kids.append(e)
    direct = []; lastdepth = None
    for e in kids:
        if lastdepth is None or e["depth"] <= lastdepth: direct.append(e); lastdepth = e["depth"]
    own = size(d["ranges"]); sub = size([r for e in direct for r in e["ranges"]])
    key = ident(d)
    excl[key] += max(own - sub, 0); copies[key] += 1
    if d["tag"] == "DW_TAG_subprogram": totsz += own
print("concrete subprogram bytes", totsz)
byfile = collections.Counter()
for (f, n), b in excl.items(): byfile[f] += b
print("by file:", ", ".join(f"{f} {b}" for f, b in byfile.most_common(8)))
for (f, n), b in excl.most_common(topn):
    print(f"{b:>9} {copies[(f, n)]:>5}  {f}:{n}")
# Optional: per concrete function breakdown (env TOPFN=N): the N biggest concrete
# subprograms and the origins of their exclusive bytes.
import os as _os
if _os.environ.get("TOPFN"):
    N = int(_os.environ["TOPFN"])
    conc = []
    for i, d in enumerate(dies):
        if d["tag"] == "DW_TAG_subprogram" and d["ranges"]:
            conc.append((size(d["ranges"]), i))
    conc.sort(reverse=True)
    for sz, i in conc[:N]:
        d = dies[i]
        agg = collections.Counter()
        for j in range(i, len(dies)):
            e = dies[j]
            if j > i and e["depth"] <= d["depth"]: break
            if e["tag"] not in ("DW_TAG_subprogram", "DW_TAG_inlined_subroutine") or not e["ranges"]: continue
            kids = []; lastdepth = None
            for f in dies[j+1:]:
                if f["depth"] <= e["depth"]: break
                if f["tag"] == "DW_TAG_inlined_subroutine" and f["ranges"]:
                    if lastdepth is None or f["depth"] <= lastdepth: kids.append(f); lastdepth = f["depth"]
            agg[ident(e)] += max(size(e["ranges"]) - size([r for f in kids for r in f["ranges"]]), 0)
        print(f"== {sz} {ident(d)} {d.get('name','')} {hex(min(r[0] for r in d['ranges']))}")
        for k, b in agg.most_common(12): print(f"     {b:>8} {k[0]}:{k[1]}")
# Optional (env ANON=N): concrete functions ranked by exclusive bytes whose origin is
# unknown ('?'), i.e. compiler-generated procs; prints linkage name and size.
if _os.environ.get("ANON"):
    N = int(_os.environ["ANON"]); rows = []
    for i, d in enumerate(dies):
        if d["tag"] != "DW_TAG_subprogram" or not d["ranges"]: continue
        if ident(d)[0] != "?": continue
        kids = []; lastdepth = None
        for f in dies[i+1:]:
            if f["depth"] <= d["depth"]: break
            if f["tag"] == "DW_TAG_inlined_subroutine" and f["ranges"]:
                if lastdepth is None or f["depth"] <= lastdepth: kids.append(f); lastdepth = f["depth"]
        ex = size(d["ranges"]) - size([r for f in kids for r in f["ranges"]])
        rows.append((ex, size(d["ranges"]), d.get("name", "?"), hex(min(r[0] for r in d["ranges"]))))
    rows.sort(reverse=True)
    print("anon concrete count", len(rows), "excl total", sum(r[0] for r in rows))
    for r in rows[:N]: print("   ", r)
