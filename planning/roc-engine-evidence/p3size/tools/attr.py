"""attr.py BINARY [topn] -- attribute .text size to Roc source function names via DWARF."""
import sys, subprocess, re, collections
binp = sys.argv[1]; topn = int(sys.argv[2]) if len(sys.argv) > 2 else 40
dw = subprocess.run(["llvm-dwarfdump-18", "--debug-info", binp], capture_output=True, text=True).stdout
names = {}
cur = {}
for line in dw.splitlines():
    if "DW_TAG_" in line:
        if cur.get("link") and cur.get("name"):
            names.setdefault(cur["link"], ((cur["name"] if not cur["name"].startswith("roc__") else "<lambda>"), cur.get("file", "?")+":"+str(cur.get("line"))))
        cur = {}
    m = re.search(r'DW_AT_linkage_name\t\("([^"]+)"\)', line)
    if m: cur["link"] = m.group(1)
    m = re.search(r'DW_AT_name\t\("([^"]+)"\)', line)
    if m: cur["name"] = m.group(1)
    m = re.search(r'DW_AT_decl_file\t\("([^"]+)"\)', line)
    if m: cur["file"] = m.group(1).split("/")[-1]
    m = re.search(r'DW_AT_decl_line\t\((\d+)\)', line)
    if m: cur["line"] = int(m.group(1))
if cur.get("link") and cur.get("name"):
    names.setdefault(cur["link"], ((cur["name"] if not cur["name"].startswith("roc__") else "<lambda>"), cur.get("file", "?")+":"+str(cur.get("line"))))
nm = subprocess.run(["nm", "-S", "--size-sort", binp], capture_output=True, text=True).stdout
agg = collections.defaultdict(lambda: [0, 0])
total = 0; roc_total = 0; unnamed = 0
for line in nm.splitlines():
    p = line.split()
    if len(p) != 4 or p[2] not in "tT": continue
    sz = int(p[1], 16); sym = p[3]; total += sz
    if not sym.startswith("roc__"):
        key = ("<host/runtime>", "")
    else:
        roc_total += sz
        base = sym.split(".")[0]
        key = names.get(base) or names.get(sym)
        if key is None:
            unnamed += sz; key = ("<unnamed roc>", "")
    agg[key][0] += sz; agg[key][1] += 1
print(f"text symbols total {total}, roc {roc_total}, unnamed roc {unnamed}")
for (n, f), (sz, c) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:topn]:
    print(f"{sz:>10} {c:>6} {sz//max(c,1):>8}  {f} {n}")
