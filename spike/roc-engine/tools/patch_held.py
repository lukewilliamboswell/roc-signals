"""Wrap the captures of when_inst, block_inst and each_inst in Held(...), the
roc-lang/roc#12846 workaround p3copy applied only to state_inst."""
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
for name, params in [('when_inst', ['w', 'cur', 'block']), ('block_inst', ['block']), ('each_inst', ['cfg', 'rows', 'cols'])]:
    head = f"\t{name} = |{', '.join(params)}| Inst(|env, msg, tx| {{"
    i = lines.index(head)
    j = next(k for k in range(i + 1, len(lines)) if lines[k] == '\t})')
    body = ['\t' + l if l else l for l in lines[i + 1:j]]
    fields = ', '.join(f'{x}: {x}0' for x in params)
    new = [f"\t{name} = |{', '.join(x + '0' for x in params)}| {{",
           f"\t\theld = Held({{ {fields} }})",
           "\t\tInst(|env, msg, tx| {",
           f"\t\t\tHeld({{ {', '.join(params)} }}) = held"] + body + ['\t\t})', '\t}']
    lines[i:j + 1] = new
open(p, 'w').write('\n'.join(lines))
