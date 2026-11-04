"""wmap.py WASM(with name section) NATIVE_DWARF_BIN SRCDIR -- wasm function sizes labelled
with the Roc origin of the same-named native symbol (hash names match across targets)."""
import sys, subprocess, re
w, nb, src = sys.argv[1:4]
names = {}
for line in subprocess.run(["wasm-objdump", "-x", "-j", "name", w], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*- func\[(\d+)\] <(.*)>", line)
    if m: names[int(m.group(1))] = m.group(2)
sizes = []
for line in subprocess.run(["wasm-objdump", "-x", "-j", "Code", w], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*- func\[(\d+)\] size=(\d+)", line)
    if m: sizes.append((int(m.group(2)), int(m.group(1))))
dw = subprocess.run(["llvm-dwarfdump-18", "--debug-info", nb], capture_output=True, text=True).stdout
lab = {}; cur = {}
def fl():
    if cur.get("link"): lab.setdefault(cur["link"], f'{cur.get("file","?")}:{cur.get("name","?")}@{cur.get("line",0)}')
for line in dw.splitlines():
    if "DW_TAG_" in line: fl(); cur = {}
    m = re.search(r'DW_AT_linkage_name\t\("([^"]+)"\)', line)
    if m: cur["link"] = m.group(1)
    m = re.search(r'DW_AT_name\t\("([^"]+)"\)', line)
    if m: cur["name"] = m.group(1)
    m = re.search(r'DW_AT_decl_file\t\("([^"]+)"\)', line)
    if m: cur["file"] = m.group(1).split("/")[-1]
    m = re.search(r'DW_AT_decl_line\t\((\d+)\)', line)
    if m: cur["line"] = int(m.group(1))
fl()
sizes.sort(reverse=True)
print("total", sum(s for s, _ in sizes))
for s, i in sizes[:int(sys.argv[4]) if len(sys.argv) > 4 else 40]:
    n = names.get(i, "?"); base = n.split(".")[0]
    print(f"{s:>8} {n[:50]:<50} {lab.get(base, '')}")
