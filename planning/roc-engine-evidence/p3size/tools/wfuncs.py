"""wfuncs.py WASM [topn] -- per-function code size from a wasm with a name section."""
import sys, subprocess, re
w = sys.argv[1]; topn = int(sys.argv[2]) if len(sys.argv) > 2 else 60
names = {}
for line in subprocess.run(["wasm-objdump", "-x", "-j", "name", w], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*- func\[(\d+)\] <(.*)>", line)
    if m: names[int(m.group(1))] = m.group(2)
sizes = []
for line in subprocess.run(["wasm-objdump", "-x", "-j", "Code", w], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*- func\[(\d+)\] size=(\d+)", line)
    if m: sizes.append((int(m.group(2)), int(m.group(1))))
sizes.sort(reverse=True)
print("total", sum(s for s, _ in sizes), "funcs", len(sizes))
for s, i in sizes[:topn]:
    print(f"{s:>8} {names.get(i, '?')}")
