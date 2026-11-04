"""scm2json.py SPEC_DIR OUT.json -- convert an example's `.scm` semantic specs
into JSON for the browser replayer (browser/replay.mjs). Every form is kept as
nested arrays; strings stay strings, symbols become {"sym": name}."""
import sys, os, json

def tokenize(s):
    toks, i = [], 0
    while i < len(s):
        c = s[i]
        if c == ';':
            while i < len(s) and s[i] != '\n': i += 1
        elif c.isspace(): i += 1
        elif c in '()': toks.append(c); i += 1
        elif c == '"':
            j, out = i + 1, []
            while s[j] != '"':
                if s[j] == '\\':
                    e = s[j + 1]
                    out.append({'n': '\n', 't': '\t'}.get(e, e)); j += 2
                else: out.append(s[j]); j += 1
            toks.append(('str', ''.join(out))); i = j + 1
        else:
            j = i
            while j < len(s) and not s[j].isspace() and s[j] not in '()': j += 1
            toks.append(('sym', s[i:j])); i = j
    return toks

def parse(toks):
    stack = [[]]
    for t in toks:
        if t == '(': stack.append([])
        elif t == ')':
            x = stack.pop(); stack[-1].append(x)
        else: stack[-1].append(t[1] if t[0] == 'str' else {'sym': t[1]})
    return stack[0]

def main():
    d, out = sys.argv[1:3]
    tests = []
    for f in sorted(os.listdir(d)):
        if not f.endswith('.scm'): continue
        for t in parse(tokenize(open(os.path.join(d, f)).read())):
            assert t[0] == {'sym': 'test'}, t[0]
            blocks = {b[0]['sym']: b[1:] for b in t[2:]}
            tests.append({'file': f[:-4], 'name': t[1], 'setup': blocks.get('setup', []), 'steps': blocks.get('steps', [])})
    json.dump(tests, open(out, 'w'), indent=1)
    print(f'{len(tests)} specs, {sum(len(t["steps"]) for t in tests)} steps -> {out}')

main()
