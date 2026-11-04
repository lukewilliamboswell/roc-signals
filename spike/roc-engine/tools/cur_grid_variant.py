"""cur_grid_variant.py SRC_DIR OUT_DIR N -- copy of the original data grid
with an N-row dataset, plus host-bench specs for mount and the measured events."""
import sys, os, shutil
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(src, out)
p = os.path.join(out, 'GridData.roc')
s = open(p).read()
s = s.replace('\trow_count = 1200\n', f'\trow_count = {n}\n')
open(p, 'w').write(s)
# the original's top-level expects pin the 1,200-row dataset
p = os.path.join(out, 'main.roc')
lines = open(p).read().split('\n')
out_l, skip = [], False
for l in lines:
    if l.startswith('expect'):
        skip = l.rstrip().endswith('{')
        continue
    if skip:
        if l.startswith('}'):
            skip = False
        continue
    out_l.append(l)
open(p, 'w').write('\n'.join(out_l))
sd = os.path.join(out, 'specs')
shutil.rmtree(sd)
os.makedirs(sd)
specs = {
    'mount': '(expect-visible (test-id "page-label"))',
    'note-edit': '(fill (label "Note for Node-0003") "needs review")',
    'select-row': '(check (label "Select Node-0004"))',
    'next-page': '(click (role button :name "Next page"))',
    'sort-score': '(click (role button :name "Sort by score"))',
    'filter': '(fill (label "Filter") "Node-1")',
}
for name, step in specs.items():
    open(os.path.join(sd, name + '.scm'), 'w').write(f'(test "{name}"\n  (steps\n    (mark-metrics)\n    {step}))\n')
