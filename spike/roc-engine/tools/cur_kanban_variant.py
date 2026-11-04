"""cur_kanban_variant.py SRC_DIR OUT_DIR N -- copy of the original kanban
board with N generated cards (same generator as the p4 bench) plus
host-bench specs for mount and the measured events on the middle Backlog card."""
import sys, os, shutil
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
mid = f"Card {(n // 2) // 4 * 4}"
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(src, out)
p = os.path.join(out, 'main.roc')
s = open(p).read()
a = s.index('initial_board : Board')
b = s.index('cards_in : List(Card)')
s = s[:a] + f'''initial_board : Board
initial_board = board_of({n})

board_of : U64 -> Board
board_of = |n| {{
	var $cards = []
	var $i = 0.U64
	while $i < n {{
		column = match $i % 4 {{
			0 => Backlog
			1 => InProgress
			2 => Review
			_ => Done
		}}
		$cards = $cards.append({{ title: "Card ${{$i.to_str()}}", column, flags: 0 }})
		$i = $i + 1
	}}
	{{ cards: canonical($cards), draft: "" }}
}}

''' + s[b:]
# the original's top-level expects pin the 5-card board; drop them in the variant
s = '\n'.join(l for l in s.split('\n') if not l.startswith('expect'))
open(p, 'w').write(s)
sd = os.path.join(out, 'specs')
shutil.rmtree(sd)
os.makedirs(sd)
specs = {
    'mount': '(expect-visible (test-id "board-total"))',
    'flag': f'(click (role button :name "Flag: {mid}"))',
    'move-right': f'(click (role button :name "Move right: {mid}"))',
    'type-draft': '(fill (label "New card title") "Fresh card")',
    'wip-limit': '(fill (label "WIP limit") "3")',
}
for name, step in specs.items():
    open(os.path.join(sd, name + '.scm'), 'w').write(f'(test "{name}"\n  (steps\n    (mark-metrics)\n    {step}))\n')
