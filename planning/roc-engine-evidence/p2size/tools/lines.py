"""lines.py BINARY [topn] -- bytes of code per source file:line using the DWARF line table
(innermost inlined location)."""
import sys, subprocess, re, collections
binp = sys.argv[1]; topn = int(sys.argv[2]) if len(sys.argv) > 2 else 50
out = subprocess.run(["llvm-dwarfdump-18", "--debug-line", binp], capture_output=True, text=True).stdout
files = {}; rows = []; per_line = collections.Counter(); per_file = collections.Counter()
seqs = 0
def flush():
    global rows
    for (a, f, l, end), nxt in zip(rows, rows[1:]):
        n = nxt[0] - a
        if end or n <= 0 or n > 1 << 20: continue
        per_line[(f, l)] += n; per_file[f] += n
    rows = []
for line in out.splitlines():
    if line.startswith("debug_line[") :
        flush(); files = {}
        continue
    m = re.match(r'file_names\[\s*(\d+)\]:', line.strip())
    if m: curf = int(m.group(1)); continue
    m = re.match(r'\s*name: "([^"]+)"', line)
    if m and 'curf' in globals(): files[curf] = m.group(1).split("/")[-1]; continue
    m = re.match(r'0x([0-9a-f]{16})\s+(\d+)\s+\d+\s+(\d+)\s+.*', line)
    if m:
        a = int(m.group(1), 16); l = int(m.group(2)); f = files.get(int(m.group(3)), "?")
        end = "end_sequence" in line
        rows.append((a, f, l, end))
        if end: flush()
flush()
tot = sum(per_file.values())
print("bytes by file (line-table attributed):", tot)
for f, n in per_file.most_common(12): print(f"{n:>10} {f}")
print("top lines:")
for (f, l), n in per_line.most_common(topn): print(f"{n:>10} {f}:{l}")
