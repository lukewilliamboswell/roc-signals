"""cur_md_variant.py SRC_DIR OUT_DIR N -- copy of the original markdown editor
whose initial document is the sample repeated N times, plus host-bench specs."""
import sys, os, shutil
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(src, out)
p = os.path.join(out, 'main.roc')
s = open(p).read()
s = s.replace('''	Ui.state(
		sample_document,
		|source| {''', f'''	Ui.state(
		Str.join_with(List.repeat(sample_document, {n}), "\\n\\n"),
		|source| {{''')
lines = s.split('\n')
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
    'mount': '(expect-visible (test-id "stat-words"))',
    'append-word': '(click (role button :name "Append a word"))',
    'toggle-numbering': '(uncheck (label "Number the outline"))',
    'reading-speed': '(select-option (label "Reading speed") "300")',
    'append-section': '(click (role button :name "Append a section"))',
}
for name, step in specs.items():
    open(os.path.join(sd, name + '.scm'), 'w').write(f'(test "{name}"\n  (steps\n    (mark-metrics)\n    {step}))\n')
