A second shape of what looks like the same defect, with no `match` on `List.replace`. The closure's captured record meets the callee's rebuilt record in one join: one branch passes the captured `block` through unchanged and the other branch rebuilds it. The leaf list below it is then copied on every call. `n21.roc`, same platform and nightly (`2026-11-03-34bd006`):

```roc
app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Inst := [Inst((U64 -> (Inst, U64)))]
Block : { tag : U64, children : List(Inst) }

noop : {} -> Inst
noop = |_| Inst(|x| (noop({}), x))

call : Inst, U64 -> (Inst, U64)
call = |Inst(f), pos| f(pos)

fire : Block, U64 -> (Block, U64)
fire = |block, pos| {
	{ tag, children } = block
	{ list, prev } = children.replace(0, noop({})) ?? crash "child"
	(next, out) = call(prev, pos + 1)
	({ tag, children: list.set(0, next) ?? crash "child" }, out)
}

site : Block -> Inst
site = |block| Inst(|pos| {
	(b2, out) = if pos >= 3 (block, pos) else fire(block, pos)
	(site(b2), out)
})

leaf : List(U64) -> Inst
leaf = |xs| Inst(|x| (leaf(xs.set(0, 7) ?? crash "empty"), x))

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = site({ tag: 0, children: [leaf(List.repeat(0, n))] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, 0)
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
```

| | dev | speed | size |
|---|---|---|---|
| as above | 0 | 2000 | 2000 |
| each branch builds its own result: `if pos >= 3 (site(block), pos) else { (b2, out) = fire(block, pos)` then `(site(b2), out) }` | 0 | 0 | 0 |
| the closure captures `Held(block)` (`Held := [Held(Block)]`) and unwraps it inside the closure body | 0 | 0 | 0 |

The 2000 allocations per 1000 calls are a copy of `children`, which raises the leaf closure's refcount, followed by a copy of the 8 MB leaf list. The same thing happens when the pass-through branch is inside `fire` itself (`if pos >= 3 (block, pos) else { ... }`).

In the engine this was reduced from, both workarounds were needed together: wrapping the state site's captures in a single-tag nominal, and making every site closure return from each routing case directly. With both, sparse updates allocate a constant number of bytes at 1k, 10k and 100k rows.
