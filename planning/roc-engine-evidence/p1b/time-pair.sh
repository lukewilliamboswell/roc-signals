#!/bin/sh
# Usage: time-pair.sh DTIMING_DIR CUR_DIR  (run under the timing lock)
"$1/timing" > "$1/timing.txt"
/tmp/claude-1000/re/p1b/run-cur.sh "$2"
python3 - "$1/timing.txt" <<'EOF'
import sys, statistics, collections
d = collections.OrderedDict()
for line in open(sys.argv[1]):
    if line.startswith('#'):
        print(line.rstrip()); continue
    p = line.split()
    d.setdefault(p[0], []).append(int(p[1]))
for k, v in d.items():
    unit = 'ns' if k == 'sparse' else 'us'
    v2 = v[1:]  # drop first (cold)
    print(f'D {k:8} n={len(v2)} median={statistics.median(v2)} {unit} min={min(v2)} max={max(v2)} (first {v[0]})')
EOF
python3 /tmp/claude-1000/re/p1b/cstat.py "$2/bench.csv"
