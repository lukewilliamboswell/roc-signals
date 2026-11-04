#!/bin/bash
# timecur.sh CURDIR... -- current-engine host-bench timings, one spec per case,
# each measurement under the shared timing lock (with a timeout). CSV next to
# $P/results/time-cur-<dir>.csv.
. "$(dirname "$0")/env.sh"
for C in "$@"; do
  T=$P/results/time-cur-$(basename $C).csv
  : > $T
  for f in $C/specs/*.scm; do
    name=$(basename $f .scm)
    warm=5; [ $name = mount ] && warm=0
    flock -w 3600 $LOCK timeout 600 $C/cur --host-bench-app --host-bench-name $name --host-bench-warmup $warm \
      --host-bench-iterations 1 --host-bench-samples 7 --host-entropy-seed 0 $f >> $T 2>> $T.err || echo "timing $name failed" >&2
  done
  python3 - $T <<'PY'
import sys, csv, statistics, collections
by = collections.OrderedDict()
for r in csv.DictReader(open(sys.argv[1])):
    if r.get('case') == 'case': continue
    by.setdefault(r['case'], []).append(r)
for case, rs in by.items():
    if case == 'mount':
        v = [int(r['init_roc_ns']) + int(r['init_apply_ns']) for r in rs]
    else:
        v = [int(r['dispatch_roc_ns']) + int(r['dispatch_apply_ns']) for r in rs]
    a = [int(r['allocs_this_event']) for r in rs]
    print(f"cur {sys.argv[1].split('time-cur-')[1][:-4]:10} {case:18} {statistics.median(v)/1e3:10.1f} us  (min {min(v)/1e3:.1f}, max {max(v)/1e3:.1f})  allocs_this_event={a[0]}")
PY
done
