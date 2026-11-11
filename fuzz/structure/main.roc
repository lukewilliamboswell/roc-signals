app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Soak
import pf.Wire
import pf.Worker

## Generated structure: bytes decode into a site tree and a session over it,
## so the engine meets nestings no fixed app happens to contain.
##
## The tree is at most 5 deep and 40 nodes, over every site kind; the only
## awaited requests are timers and worker jobs:
## - `Show(i)`: a text reading a visible layer; `Bump(i)`: a button whose
##   click adds 1 to a writable layer (a `state`, or a component's outward
##   action that the caller's sink turns into the same write);
##   `Bump2(i, j)`: inside a component, a button that pushes two actions in
##   one click, so the caller's sink writes two of its layers in one turn
##   (elsewhere, and in mode 0, it is a `Bump(i)`);
## - `When(i, yes, no)` on a layer's parity and `Switch(i, a, b, c)` on it
##   modulo 3;
## - `Layer(kind, i, body)`: a `state`, a `derive` of a layer, a `resource`
##   whose `pending` follows its input, a `resource` that issues a timer and
##   counts its answers, or a `resource` that issues a worker job for its
##   input and folds its output, its loss or its timeout; each shows its own
##   value and a `state` gets a button of its own;
## - `Each(i, body)`: rows whose keys are a layer-dependent permutation, each
##   row showing its key and holding `body` in a component;
## - `Comp(body)`: a component whose prop is every visible layer and whose
##   actions write every visible writable;
## - `Watch(k, i)`: a `watch`, `on_change` or `latest` that sets the title.
##
## Outside components, layers nest at most three deep below the root state
## (the generator's typed levels); deeper layers and every `Each` row and
## `Comp` body go through a component, whose body has the same three levels
## again. That keeps the generator monomorphic: a recursive generator over
## the typed contexts would need polymorphic recursion (roc-lang/roc#12835).
##
## The session clicks any live button or answers any live request: a timer
## fires; a worker job is answered by its task's stand-in (`triple`), or is lost
## (`WorkLost(AppCrash)`) or times out. Oracles:
## - every step leaves the engine settled (`Core.settled`);
## - in mode 0 every write goes to the root state (other states stay at
##   their initial value and resources issue nothing), so the page is a
##   function of the root's value: after every step the rendered DOM must
##   equal a fresh mount whose root starts at the number of clicks so far;
## - the session frees everything it allocated.

Node := [
	Show(U64),
	Bump(U64),
	Bump2(U64, U64),
	When(U64, List(Node), List(Node)),
	Switch(U64, List(Node), List(Node), List(Node)),
	Layer(U64, U64, List(Node)),
	Each(U64, List(Node)),
	Comp(List(Node)),
	Watch(U64, U64),
]

# ------------------------------------------------------------------ decoding

Reader : { bytes : List(U8), pos : U64, left : U64 }

next : Reader -> (U64, Reader)
next = |d| ((d.bytes.get(d.pos) ?? 0).to_u64(), { ..d, pos: d.pos + 1 })

nodes : Reader, U64 -> (List(Node), Reader)
nodes = |d0, depth| {
	(b, d1) = next(d0)
	count = if (depth == 0) 0 else b % 4
	var $d = d1
	var $out = []
	var $k = 0.U64
	while $k < count and $d.left > 0 {
		(n, d2) = node({ ..$d, left: $d.left - 1 }, depth - 1)
		$out = $out.append(n)
		$d = d2
		$k = $k + 1
	}
	($out, $d)
}

node : Reader, U64 -> (Node, Reader)
node = |d0, depth| {
	(b, d1) = next(d0)
	(i, d2) = next(d1)
	match b % 10 {
		0 | 1 => (Show(i), d2)
		2 =>
			if (b // 10) % 2 == 0 {
				(Bump(i), d2)
			} else {
				(j, d3) = next(d2)
				(Bump2(i, j), d3)
			}
		3 => {
			(yes, d3) = nodes(d2, depth)
			(no, d4) = nodes(d3, depth)
			(When(i, yes, no), d4)
		}
		4 => {
			(a, d3) = nodes(d2, depth)
			(c1, d4) = nodes(d3, depth)
			(c2, d5) = nodes(d4, depth)
			(Switch(i, a, c1, c2), d5)
		}
		5 | 6 => {
			(body, d3) = nodes(d2, depth)
			(Layer(b // 10, i, body), d3)
		}
		7 => {
			(body, d3) = nodes(d2, depth)
			(Each(i, body), d3)
		}
		8 => {
			(body, d3) = nodes(d2, depth)
			(Comp(body), d3)
		}
		_ => (Watch(b // 10, i), d2)
	}
}

decode : List(U8) -> List(Node)
decode = |bytes| nodes({ bytes, pos: 0, left: 40 }, 5).0

# ---------------------------------------------------------------- generating

## A writable layer: a state, or a component's action `j`.
Wr(ctx) : [St(Core.State(ctx, U64)), Out(Core.State(ctx, List(U64)), U64)]

## What a node can read and write where it is built. `pure`: writes go to the
## root only and resources issue nothing (mode 0).
G(ctx) : { vals : List(Core.Val(ctx, U64)), wrs : List(Wr(ctx)), pure : Bool }

## The context of every component body.
C0 : Core.Comp(List(U64), U64)

## How to build what nests below a layer, and a component body.
Inner(ctx) : { layer : (List(Node), G(Core.In(ctx, U64)) -> Core.Elem(Core.In(ctx, U64))), comp : (List(Node), G(C0) -> Core.Elem(C0)) }

## 0, 1, ... `n - 1`.
upto : U64 -> List(U64)
upto = |n| {
	var $out = []
	var $k = 0.U64
	while $k < n {
		$out = $out.append($k)
		$k = $k + 1
	}
	$out
}

pick : List(a), U64, a -> a
pick = |l, i, fallback| l.get(i % l.len().max(1)) ?? fallback

val_of : G(ctx), U64 -> Core.Val(ctx, U64)
val_of = |g, i| pick(g.vals, i, Core.const(0))

lift_wr : Wr(ctx) -> Wr(Core.In(ctx, U64))
lift_wr = |w| match w {
	St(s) => St(s.lift())
	Out(o, j) => Out(o.lift(), j)
}

lift_wr_row : Wr(ctx) -> Wr(Core.Row(ctx, U64))
lift_wr_row = |w| match w {
	St(s) => St(s.lift_row())
	Out(o, j) => Out(o.lift_row(), j)
}

bump_of : Wr(ctx) -> Core.Handler(ctx)
bump_of = |w| match w {
	St(s) => s.update(|n| n + 1)
	Out(o, j) => o.push(j)
}

sink_one : Wr(ctx) -> Core.Sink(ctx, {})
sink_one = |w| match w {
	St(s) => Core.sink(s, |n, _| n + 1)
	Out(o, j) => Core.sink(o, |l, _| l.append(j))
}

## Action `i` writes the `i`-th writable.
sink_of : List(Wr(ctx)) -> Core.Sink(ctx, U64)
sink_of = |wrs| match wrs {
	[] => Core.discard({})
	[w, .. as rest] => Core.split(sink_one(w), sink_of(rest), |i| if (i == 0) L({}) else R(i - 1))
}

## A button whose click adds 1 to writable `i` (none when nothing is
## writable).
bump_button : G(ctx), U64 -> Core.Elem(ctx)
bump_button = |g, i|
	match g.wrs.get(i % g.wrs.len().max(1)) {
		Ok(w) => Core.element("button", [Core.on_click(bump_of(w))], [Core.text("+")])
		Err(_) => Core.text("-")
	}

show : Core.Val(ctx, U64) -> Core.Elem(ctx)
show = |v| Core.text_v(v.map(|n| n.to_str()))

## A component over everything `g` sees: the prop lists the visible layers,
## action `j` writes writable `j`.
via_comp : List(Node), G(ctx), (List(Node), G(C0) -> Core.Elem(C0)) -> Core.Elem(ctx)
via_comp = |ns, g, comp| {
	prop = g.vals.fold(Core.const([]), |acc, v| acc.map2(v, |l, x| l.append(x)))
	nv = g.vals.len()
	nw = g.wrs.len()
	pure = g.pure
	Core.component(
		prop,
		sink_of(g.wrs),
		|p, out| {
			vals = upto(nv).map(|k| p.map(|l| l.get(k) ?? 0))
			wrs = upto(nw).map(|k| Out(out, k))
			comp(ns, { vals, wrs, pure })
		},
	)
}

flat_list : List(Node), G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat_list = |ns, g, inner| Core.element("div", [], ns.map(|n| flat(n, g, inner)))

flat : Node, G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat = |n, g, inner| match n {
	Show(i) => show(val_of(g, i))
	Bump(i) => bump_button(g, i)
	Bump2(i, j) => {
		count = g.wrs.len().max(1)
		match (g.wrs.get(i % count), g.wrs.get(j % count)) {
			(Ok(Out(o, a)), Ok(Out(_, b))) if !g.pure => Core.element("button", [Core.on_click(o.update(|l| l.append(a).append(b)))], [Core.text("++")])
			_ => bump_button(g, i)
		}
	}
	When(i, yes, no) => Core.when(val_of(g, i).map(|x| x % 2 == 0), || flat_list(yes, g, inner), || flat_list(no, g, inner))
	Switch(i, a, b, c) => Core.switch(val_of(g, i).map(|x| x % 3), [0, 1, 2], |k| flat_list(if (k == 0) a else if (k == 1) b else c, g, inner))
	Layer(kind, i, body) => {
		v = val_of(g, i)
		lifted = g.vals.map(|x| x.lift())
		lwrs = g.wrs.map(lift_wr)
		pure = g.pure
		layer = inner.layer
		k = kind % 5
		if k == 0 {
			Core.state(
				0.U64,
				|st| {
					own = if (pure) [] else [Core.element("button", [Core.on_click(st.update(|x| x + 1))], [Core.text("+")])]
					g2 = { vals: lifted.append(st.val()), wrs: if (pure) lwrs else lwrs.append(St(st)), pure }
					Core.element("p", [], [show(st.val())].concat(own).append(layer(body, g2)))
				},
			)
		} else if k == 1 {
			Core.derive(v.map(|x| x * 2 + 1), |d| Core.element("p", [], [show(d), layer(body, { vals: lifted.append(d), wrs: lwrs, pure })]))
		} else if k == 2 or pure {
			Core.resource(v, { init: 0.U64, pending: |_, a| a + 7, plan: |_| [], resolve: |s, _, _| s }, |r| Core.element("p", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure })]))
		} else if k == 3 {
			Core.resource(v, { init: 0.U64, pending: |_, a| a * 10, plan: |_| [Timer(10)], resolve: |s, _, _| s + 1 }, |r| Core.element("p", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure })]))
		} else {
			Core.resource(v, job_cfg, |r| Core.element("p", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure })]))
		}
	}
	Each(i, body) => {
		rows = val_of(g, i).map(
			|x| {
				upto(x % 5).map(|j| (j * (x + 3) + x) % 7).fold([], |acc, k| if (acc.contains(k)) acc else acc.append(k))
			},
		)
		vals = g.vals
		wrs = g.wrs
		pure = g.pure
		comp = inner.comp
		Core.each(
			rows,
			|k| k.to_str(),
			|row| {
				item = row.field(|k| k)
				g2 = { vals: vals.map(|x| x.lift_row()).append(item), wrs: wrs.map(lift_wr_row), pure }
				Core.element("li", [], [show(item), via_comp(body, g2, comp)])
			},
		)
	}
	Comp(body) => via_comp(body, g, inner.comp)
	Watch(k, i) => {
		v = val_of(g, i)
		plan = |x| [Title("t${x.to_str()}")]
		if k % 3 == 0 {
			Core.watch(v, plan, Core.ignore({}))
		} else if k % 3 == 1 {
			Core.on_change(v, plan, Core.ignore({}))
		} else {
			Core.latest(v, plan, Core.ignore({}))
		}
	}
}

## Every input byte tripled: the one worker task's calculation.
triple : List(U8) -> List(U8)
triple = |bytes| bytes.map(|x| x.times_wrap(3))

## The one worker task, from bytes to bytes.
tripler : Worker.Task(Wire.Bytes, Wire.Bytes, Worker.Never)
tripler = Worker.task({ name: "roc-signals.test/structure/triple", run!: |bytes| Ok(Wire.Bytes.from_list(triple(bytes.to_list()))) })

## A job's answer as the walk gives it, with no worker to run it: the
## task's stand-in, from `triple`.
tripled : List(U8) -> List(U8)
tripled = |input| (tripler.stand_in(|bytes| Ok(Wire.Bytes.from_list(triple(bytes.to_list())))))([], input)

## A layer that follows a worker job for its input: the output's byte sum,
## or a marker for a lost or timed-out job.
job_cfg : { init : U64, pending : (U64, U64 -> U64), plan : (U64 -> List(Core.Req)), resolve : (U64, U64, Core.Res -> U64) }
job_cfg = {
	init: 0,
	pending: |_, a| a + 3,
	plan: |a| [tripler.request(Wire.Bytes.from_list([a.to_u8_wrap(), 1]))],
	resolve: |s, _, res| match res {
		Work(_) =>
			match tripler.result(res) {
				Ok(out) => out.to_list().fold(0, |acc, x| acc + x.to_u64())
				Err(_) => s + 3000
			}
		WorkLost(_) => s + 1000
		Timeout => s + 2000
		_ => s
	},
}

# The typed levels. Layers outside a component nest three deep below the
# root state (R1); a component body (C0) has three levels of its own. The
# deepest level's layers and every component body go through `via_comp`.

R1 : Core.In(Core.Root, U64)

R2 : Core.In(R1, U64)

R3 : Core.In(R2, U64)

R4 : Core.In(R3, U64)

C1 : Core.In(C0, U64)

C2 : Core.In(C1, U64)

C3 : Core.In(C2, U64)

comp_top : List(Node), G(C0) -> Core.Elem(C0)
comp_top = |ns, g| flat_list(ns, g, { layer: comp_l2, comp: comp_top })

comp_l2 : List(Node), G(C1) -> Core.Elem(C1)
comp_l2 = |ns, g| flat_list(ns, g, { layer: comp_l3, comp: comp_top })

comp_l3 : List(Node), G(C2) -> Core.Elem(C2)
comp_l3 = |ns, g| flat_list(ns, g, { layer: comp_deep, comp: comp_top })

comp_deep : List(Node), G(C3) -> Core.Elem(C3)
comp_deep = |ns, g| via_comp(ns, g, comp_top)

root_l2 : List(Node), G(R2) -> Core.Elem(R2)
root_l2 = |ns, g| flat_list(ns, g, { layer: root_l3, comp: comp_top })

root_l3 : List(Node), G(R3) -> Core.Elem(R3)
root_l3 = |ns, g| flat_list(ns, g, { layer: root_deep, comp: comp_top })

root_deep : List(Node), G(R4) -> Core.Elem(R4)
root_deep = |ns, g| via_comp(ns, g, comp_top)

## The page: the root state starting at `init`, then the tree.
view : List(Node), Bool, U64 -> Core.Elem(Core.Root)
view = |tree, pure, init| Core.state(
	init,
	|st| Core.element(
		"main",
		[],
		[
			show(st.val()),
			Core.element("button", [Core.on_click(st.update(|x| x + 1))], [Core.text("+")]),
			flat_list(tree, { vals: [st.val()], wrs: [St(st)], pure }, { layer: root_l2, comp: comp_top }),
		],
	),
)

# ------------------------------------------------------------------- session

## The engine, the oracle's DOM, the clicks so far, and the worker jobs
## issued and not yet answered or cancelled (id and input).
S : { eng : Core.App, dom : Dom.Model, clicks : U64, jobs : List((U32, List(U8))) }

## Mount through the program's driver, so the worker catalogue is the one
## a host would see.
mount : List(Node), Bool, U64 -> S
mount = |tree, pure, init| {
	program = Core.program(|| view(tree, pure, init)).with_workers([tripler.registration()])
	(a, c, _) = (Core.driver(program).init)([])
	absorb({ eng: a, dom: Dom.new({}), clicks: 0, jobs: [] }, a, c)
}

## Apply one batch to the oracle, keeping track of the worker jobs it issued
## or cancelled.
absorb : S, Core.App, List(U8) -> S
absorb = |s, a, c| {
	(dom, _, fx) = Dom.apply_fx(s.dom, c)
	jobs = fx.fold(
		s.jobs,
		|acc, cmd| match cmd {
			Work(id, job) => acc.append((id, job.input))
			Cancel(id) => acc.keep_if(|(j, _)| j != id)
			_ => acc
		},
	)
	{ ..s, eng: a, dom, jobs }
}

## The DOM as markup with each element's attributes sorted, so two models
## built along different paths compare by content.
render : Dom.Model, U64 -> Str
render = |dom, i| {
	n = Dom.node(dom, i)
	if n.tag == "" {
		n.text
	} else {
		attrs = n.attrs.sort_with(|(a, _), (b, _)| compare_bytes(a.to_utf8(), b.to_utf8())).map(|(k, v)| " ${k}=\"${v}\"")
		"<${n.tag}${Str.join_with(attrs, "")}>${Str.join_with(n.kids.map(|k| render(dom, k)), "")}</${n.tag}>"
	}
}

## Lexicographic order of two byte strings.
compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b| {
	var $k = 0.U64
	while $k < a.len() and $k < b.len() {
		x = a.get($k) ?? 0
		y = b.get($k) ?? 0
		if x < y {
			return Before
		}
		if x > y {
			return After
		}
		$k = $k + 1
	}
	if (a.len() < b.len()) Before else if (a.len() > b.len()) After else Same
}

settle_check : S, Str -> S
settle_check = |s, what|
	match Core.settled(s.eng) {
		Ok(_) => s
		Err({ cmds, note }) => crash "${what}: a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(s.dom, cmds).1)} ${note}"
	}

## Mode 0: the page must equal a fresh mount at the root's current value.
scratch_check : S, List(Node), Str -> S
scratch_check = |s, tree, what| {
	fresh = mount(tree, Bool.True, s.clicks)
	got = render(s.dom, s.dom.root)
	want = render(fresh.dom, fresh.dom.root)
	if got != want {
		crash "${what}: the page differs from a fresh mount at root ${s.clicks.to_str()}:\n  walked ${got}\n  fresh  ${want}"
	}
	s
}

step : S, U64, U64 -> (S, Str)
step = |s, op, b| {
	if op % 4 == 3 {
		match Core.fx_live(s.eng).get(b % Core.fx_live(s.eng).len().max(1)) {
			Ok(id) => {
				(res, what) = match s.jobs.find_first(|(j, _)| j == id) {
					Ok((_, input)) =>
						if b % 5 == 0 {
							(WorkLost(AppCrash), "lose job")
						} else if b % 5 == 1 {
							(Timeout, "time out job")
						} else {
							(Work({ output: tripled(input), files: [] }), "run job")
						}
					Err(_) => (Fired, "fire timer")
				}
				(a, c) = Core.take_cmds(Core.result(s.eng, id, res), [])
				(absorb({ ..s, jobs: s.jobs.keep_if(|(j, _)| j != id) }, a, c), "${what} ${id.to_str()}")
			}
			Err(_) => (s, "no answer")
		}
	} else {
		cs = Soak.candidates(s.dom)
		match cs.get(b % cs.len().max(1)) {
			Ok((i, ev)) =>
				match Dom.target(s.dom, i, ev) {
					Ok((id, h)) => {
						(a, c) = Core.take_cmds(Core.event(s.eng, id, h, ""), [])
						(absorb({ ..s, clicks: s.clicks + 1 }, a, c), "click node ${id.to_str()}")
					}
					Err(_) => (s, "no handler")
				}
			Err(_) => (s, "nothing to click")
		}
	}
}

run : List(Node), Bool, List(U8) -> {}
run = |tree, pure, events| {
	var $s = settle_check(mount(tree, pure, 0), "mount")
	var $i = 0.U64
	while $i + 1 < events.len() {
		(s1, what0) = step($s, (events.get($i) ?? 0).to_u64(), (events.get($i + 1) ?? 0).to_u64())
		what = "step ${($i // 2).to_str()} (${what0})"
		s2 = settle_check(s1, what)
		$s = if (pure) scratch_check(s2, tree, what) else s2
		$i = $i + 2
	}
	{}
}

Input : { mode : U8, tree : List(U8), events : List(U8) }

## Mode 2: a seeded series of generated trees and sessions.
series : U64, U64 -> {}
series = |seed, count| {
	var $x = seed
	var $k = 0.U64
	while $k < count {
		var $bytes = []
		var $j = 0.U64
		while $j < 160 {
			$x = Soak.prng($x)
			$bytes = $bytes.append($x.shr_zf_wrap(40).to_u8_wrap())
			$j = $j + 1
		}
		tree = decode($bytes.take_first(80))
		run(tree, $k % 2 == 0, $bytes.drop_first(80))
		$k = $k + 1
	}
	{}
}

test! : Input => Fuzz.Outcome
test! = |{ mode, tree, events }| {
	if mode == 2 {
		Fuzz.expect_no_leaks!(|| series(11 + tree.len().to_u64(), 400))
	} else {
		Fuzz.expect_no_leaks!(|| run(decode(tree), mode == 0, events))
	}
	Fuzz.keep
}

ex : Str, U8, List(U8), List(U8) -> Fuzz.Example(Input)
ex = |name, mode, tree, events| Fuzz.example({ name, revision: "1", make: || { mode, tree, events } })

target = Fuzz.target_with!({
	name: "structure",
	examples: [
		# `When(0, [Show(0)], [Layer(state, 0, [Show(1), Bump(1)])])`: a state
		# that exists only in the branch the `when` mounts second, outside any
		# component, written by its own button and by a `Bump`.
		ex("late-state", 1, [1, 3, 0, 1, 0, 0, 1, 5, 0, 2, 0, 1, 2, 1], [0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 1]),
		# `Comp([Layer(state, 0, [Layer(state, 0, [Comp([Bump2(1, 2)])])])])`:
		# one click pushes two actions that the sink routes to two nested
		# states of a component body, written in one turn (issue #175).
		ex("two-writes", 1, [1, 8, 0, 1, 5, 0, 1, 5, 0, 1, 8, 0, 1, 12, 1, 2], [0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5]),
		ex("series", 2, [], []),
	],
	generator: { mode: Fuzz.u8_in(0, 1), tree: Fuzz.list(Fuzz.u8, 80), events: Fuzz.list(Fuzz.u8, 80) }.Fuzz,
	test!,
	show: Str.inspect,
})
