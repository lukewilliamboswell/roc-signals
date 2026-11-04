"""to_module.py SRC.roc OUT.roc MODULE START_MARK END_MARK [EXTRA_TYPE ...]

Lift an example's top-level domain code (lines between START_MARK and
END_MARK) into a type module `MODULE := [].{ ... }`, qualifying references to
its own top-level values and types with `MODULE.`. Top-level `expect`s and
`import`s are dropped (the originals keep them as tests)."""
import sys, re
src, out, mod, start, end = sys.argv[1:6]
s = open(src).read()
a = s.index(start)
b = s.index(end) if end != '-' else len(s)
body = s[a:b]
lines = body.split('\n')
# drop top-level expects (single line or block)
kept, skip = [], False
for l in lines:
    if l.startswith('expect'):
        skip = l.rstrip().endswith('{')
        continue
    if skip:
        if l.startswith('}'):
            skip = False
        continue
    if l.startswith('import '):
        continue
    kept.append(l)
lines = kept
vals = set(); types = set()
for l in lines:
    m = re.match(r'^([a-z_][a-z0-9_]*) :', l)
    if m: vals.add(m.group(1))
    m = re.match(r'^([A-Z][A-Za-z0-9]*) (:=|:)', l)
    if m: types.add(m.group(1))
types |= set(sys.argv[6:])
outl = []
for l in lines:
    m = re.match(r'^([a-z_][a-z0-9_]*|[A-Z][A-Za-z0-9]*)( :=| :| =)(.*)$', l)
    head, rest = ('', l)
    if m:
        head, rest = m.group(1) + m.group(2), m.group(3)
    def q(t):
        t = re.sub(r'(?<![.\w])(' + '|'.join(sorted(types, key=len, reverse=True)) + r')\b(?!\s*:=)', mod + r'.\1', t) if types else t
        t = re.sub(r'(?<![.\w$])(' + '|'.join(sorted(vals, key=len, reverse=True)) + r')\b(?!\s*[:=]\s)', mod + r'.\1', t) if vals else t
        return t
    # do not rewrite inside string literals (cheap: split on quotes)
    parts = rest.split('"')
    parts = [q(p) if i % 2 == 0 else p for i, p in enumerate(parts)]
    outl.append('\t' + head + '"'.join(parts) if l else l)
res = f'{mod} := [].{{\n' + '\n'.join(outl) + '\n}\n'
open(out, 'w').write(res)
print(f'{len(vals)} values, {len(types)} types -> {out}')
