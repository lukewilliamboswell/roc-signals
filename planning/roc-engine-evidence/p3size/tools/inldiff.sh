#!/bin/bash
# inldiff.sh A B [n] -- per-function exclusive-bytes delta between two native/<name> builds
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p3size
for x in $1 $2; do [ -f $P/native/$x/inl.txt ] || python3 -I $P/tools/inl.py $P/native/$x/t $P/native/$x 100000 > $P/native/$x/inl.txt; done
python3 -I - $P/native/$1/inl.txt $P/native/$2/inl.txt ${3:-30} <<'PY'
import sys, re
def load(p):
    d = {}
    for l in open(p):
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)$", l)
        if m: d[m.group(3)] = (int(m.group(1)), int(m.group(2)))
    return d
a, b = load(sys.argv[1]), load(sys.argv[2]); n = int(sys.argv[3])
keys = set(a) | set(b)
rows = sorted(((b.get(k, (0,0))[0] - a.get(k, (0,0))[0], k) for k in keys), reverse=True)
print("total delta", sum(r[0] for r in rows))
for dlt, k in rows[:n]:
    print(f"{dlt:>8}  copies {a.get(k,(0,0))[1]:>4} -> {b.get(k,(0,0))[1]:>4}  {k}")
PY
