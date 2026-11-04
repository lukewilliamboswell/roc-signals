import sys, statistics, collections
d = collections.OrderedDict()
for line in open(sys.argv[1]):
    if line.startswith('#'):
        print(line.rstrip()); continue
    p = line.split()
    d.setdefault(p[0], []).append(int(p[1]))
for k, v in d.items():
    unit = 'ns' if k == 'sparse' else 'us'
    v2 = v[1:]
    print(f'{k:8} n={len(v2)} median={statistics.median(v2)} {unit} min={min(v2)} max={max(v2)}')
