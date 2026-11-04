import sys, statistics, collections
d = collections.OrderedDict()
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 3:
        d.setdefault(p[0], []).append(int(p[1]))
for k, v in d.items():
    print(f'{k:24} n={len(v):>3} median={statistics.median(v)/1000:9.3f} ms  min={min(v)/1000:9.3f}  max={max(v)/1000:9.3f}')
