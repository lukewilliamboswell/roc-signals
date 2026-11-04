"""tstat.py P4_TIMING_TXT CURDIR... -- medians: p4 (drop first sample of each
case) vs the current engine's host-bench CSVs (init = mount, dispatch = event)."""
import sys, os, csv, statistics, collections
p4 = collections.OrderedDict()
for line in open(sys.argv[1]):
    n, case, ns = line.split()
    p4.setdefault((n, case), []).append(int(ns))
print('# p4 engine (native --opt=speed), median of 10 (first sample dropped)')
for (n, case), v in p4.items():
    v2 = v[1:] if len(v) > 1 else v
    print(f'p4  n={n:>4} {case:16} {statistics.median(v2)/1e3:10.1f} us  (min {min(v2)/1e3:.1f}, max {max(v2)/1e3:.1f})')
print('# current engine (ReleaseFast host, --host-bench-app), median of 7')
for c in sys.argv[2:]:
    t = os.path.join(os.path.dirname(sys.argv[1]), f'time-{os.path.basename(sys.argv[1]).split("-p4")[0][5:]}-cur-{os.path.basename(c)}.csv')
    rows = [r for r in csv.DictReader(open(t)) if r.get('case') != 'case']
    by = collections.OrderedDict()
    for r in rows:
        by.setdefault(r['case'], []).append(r)
    for case, rs in by.items():
        if case == 'mount':
            v = [int(r['init_roc_ns']) + int(r['init_apply_ns']) for r in rs]
        else:
            v = [int(r['dispatch_roc_ns']) + int(r['dispatch_apply_ns']) for r in rs]
        print(f'cur {os.path.basename(c):10} {case:16} {statistics.median(v)/1e3:10.1f} us  (min {min(v)/1e3:.1f}, max {max(v)/1e3:.1f})')
