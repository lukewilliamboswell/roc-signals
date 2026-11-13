app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.SpecRunner
import pf.Wire
import pf.Worker

## Generated structure: bytes decode into a site tree and a session over it,
## so the engine meets nestings no fixed app happens to contain.
##
## The tree is at most 5 deep and 40 nodes, over every site kind; the only
## awaited requests are timers and worker jobs:
## - `Control(i)`: text and checkbox properties reading a layer, including
##   inside row templates; equality pruning is checked by the settle pass
##   and their final values by the fresh-mount model;
## - `Show(i)`: a text reading a visible layer; `Bump(i)`: a button whose
##   click adds 1 to a writable layer (a `state`); `Bump2(i, j)`: a button
##   whose click adds 1 to two writable layers as one event, one handler
##   composed of both writes (in mode 0 it is a `Bump(i)`);
## - `Pair(i, j)`: a `derive` of visible layer `i` and, below it, a text and
##   a `watch` that read layer `i`, the derived value and layer `j` together,
##   as `pair x~d~y`. Whatever an event writes, `d` is `x * 2 + 1` once every
##   write is in place and the `derive` has followed, so a text or a title
##   in which it is not is one new value seen beside one old one;
## - `When(i, yes, no)` on a layer's parity and `Switch(i, a, b, c)` on it
##   modulo 3;
## - `Layer(kind, i, body)`: a `state`, a `derive` of a layer, a `resource`
##   whose `pending` follows its input, a `resource` that issues a timer and
##   counts its answers, or a `resource` that issues a worker job for its
##   input and folds its output, its loss or its timeout; each shows its own
##   value and a `state` gets a button of its own;
## - `Each(i, body)`: rows whose keys are a layer-dependent permutation, each
##   row showing its key and holding `body`;
## - `Watch(k, i)`: a `watch`, `on_change` or `latest` that sets the title.
##
## The contexts a tree can nest through are typed by hand (the generator's
## levels): three layers below the root state, a row at each of the first
## three levels, and one layer inside a row. Below the last level a `Layer`
## or an `Each` draws its body in place and adds no scope. That keeps the
## generator monomorphic: a recursive generator over the typed contexts
## would need polymorphic recursion (roc-lang/roc#12835).
##
## The session clicks any live button or answers any live request: a timer
## fires; a worker job is answered by its task's stand-in (`triple`), or is lost
## (`WorkLost(AppCrash)`) or times out. Oracles:
## - every step leaves the engine settled (`Core.settled`);
## - no reader sees an event half applied: a turn writes a node at most
##   once and never writes a node it created, and every title a `Pair` sets
##   names a derived value that follows its layer. A reader evaluated
##   between two of an event's writes, or before a `derive` above it has
##   followed one of them, breaks one of the two;
## - in mode 0 every write goes to the root state (other states stay at
##   their initial value and resources issue nothing), so the page is a
##   function of the root's value: after every step the rendered DOM must
##   equal a fresh mount whose root starts at the number of clicks so far;
## - the session frees everything it allocated.

Node := [
	Show(U64),
	Control(U64),
	Bump(U64),
	Bump2(U64, U64),
	Pair(U64, U64),
	When(U64, List(Node), List(Node)),
	Switch(U64, List(Node), List(Node), List(Node)),
	Layer(U64, U64, List(Node)),
	Each(U64, List(Node)),
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
		0 | 1 =>
			if b >= 20 {
				(Control(i), d2)
			} else if (b // 10) % 2 == 0 {
				(Show(i), d2)
			} else {
				(j, d3) = next(d2)
				(Pair(i, j), d3)
			}
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
		7 | 8 => {
			(body, d3) = nodes(d2, depth)
			(Each(i, body), d3)
		}
		_ => (Watch(b // 10, i), d2)
	}
}

decode : List(U8) -> List(Node)
decode = |bytes| nodes({ bytes, pos: 0, left: 40 }, 5).0

# ---------------------------------------------------------------- generating

## What a node can read and write where it is built. `pure`: writes go to the
## root only and resources issue nothing (mode 0).
G(ctx) : { vals : List(Core.Signal(ctx, U64)), wrs : List(Core.State(ctx, U64)), pure : Bool }

## How to build what nests below a layer and inside a row, at a level that
## has typed levels below it; at the bottom, a layer's or a row's body is
## drawn in place.
Inner(ctx) : [
	Below({ layer : (List(Node), G(Core.In(ctx, U64)) -> Core.Elem(Core.In(ctx, U64))), row : (List(Node), G(Core.Row(ctx, U64)) -> Core.Elem(Core.Row(ctx, U64))) }),
	Bottom,
]

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

val_of : G(ctx), U64 -> Core.Signal(ctx, U64)
val_of = |g, i| pick(g.vals, i, Core.const(0))

## A button whose click adds 1 to writable `i` (none when nothing is
## writable).
bump_button : G(ctx), U64 -> Core.Elem(ctx)
bump_button = |g, i|
	match g.wrs.get(i % g.wrs.len().max(1)) {
		Ok(w) => Core.element("button", [Core.on_with("click", { prevent: i % 2 == 0, stop: i % 3 == 0 }, w.update(|n| n + 1))], [Core.text("+")])
		Err(_) => Core.text("-")
	}

show : Core.Signal(ctx, U64) -> Core.Elem(ctx)
show = |v| Core.text_s(v.map(|n| n.to_str()))

flat_list : List(Node), G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat_list = |ns, g, inner| Core.element("div", [], ns.map(|n| flat(n, g, inner)))

flat : Node, G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat = |n, g, inner| match n {
	Show(i) => show(val_of(g, i))
	Control(i) => Core.element(
		"div",
		[],
		[
			Core.element("input", [Core.attr("type", "text"), Core.prop_s(Core.Prop.value, val_of(g, i).map(|value| value.to_str()))], []),
			Core.element("input", [Core.attr("type", "checkbox"), Core.prop_s(Core.Prop.checked, val_of(g, i).map(|value| value % 2 == 0))], []),
		],
	)
	Bump(i) => bump_button(g, i)
	Bump2(i, j) => {
		count = g.wrs.len().max(1)
		match (g.wrs.get(i % count), g.wrs.get(j % count)) {
			(Ok(first), Ok(second)) if !g.pure => Core.element("button", [Core.on_click(first.update(|x| x + 1).also(second.update(|x| x + 1)))], [Core.text("++")])
			_ => bump_button(g, i)
		}
	}
	Pair(i, j) => {
		layer_i = val_of(g, i)
		layer_j = val_of(g, j)
		Core.derive(
			layer_i.map(|x| x * 2 + 1),
			|d| {
				tied = layer_i.lift().map2(d, |x, twice| "${x.to_str()}~${twice.to_str()}")
				seen = tied.map2(layer_j.lift(), |both, y| "${pair_mark}${both}~${y.to_str()}")
				Core.element("p", [], [Core.text_s(seen), Core.watch(seen, |text| [Title(text)], Core.ignore({}))])
			},
		)
	}
	When(i, yes, no) => Core.when(val_of(g, i).map(|x| x % 2 == 0), || flat_list(yes, g, inner), || flat_list(no, g, inner))
	Switch(i, a, b, c) => Core.switch(val_of(g, i).map(|x| x % 3), [0, 1, 2], |k| flat_list(if (k == 0) a else if (k == 1) b else c, g, inner))
	Layer(kind, i, body) => match inner {
		Bottom => flat_list(body, g, Bottom)
		Below({ layer, .. }) => {
			v = val_of(g, i)
			lifted = g.vals.map(|x| x.lift())
			lwrs = g.wrs.map(|w| w.lift())
			pure = g.pure
			k = kind % 5
			if k == 0 {
				Core.state(
					0.U64,
					|st| {
						own = if (pure) [] else [Core.element("button", [Core.on_click(st.update(|x| x + 1))], [Core.text("+")])]
						g2 = { vals: lifted.append(st.signal()), wrs: if (pure) lwrs else lwrs.append(st), pure }
						Core.element("p", [], [show(st.signal())].concat(own).append(layer(body, g2)))
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
	}
	Each(i, body) => match inner {
		Bottom => flat_list(body, g, Bottom)
		Below({ row, .. }) => {
			rows = val_of(g, i).map(
				|x| {
					upto(x % 5).map(|j| (j * (x + 3) + x) % 7).fold([], |acc, k| if (acc.contains(k)) acc else acc.append(k))
				},
			)
			vals = g.vals
			wrs = g.wrs
			pure = g.pure
			Core.each(
				rows,
				|k| k.to_str(),
				|r| {
					item = r.field(|k| k)
					g2 = { vals: vals.map(|x| x.lift_row()).append(item), wrs: wrs.map(|w| w.lift_row()), pure }
					Core.element("li", [], [show(item), row(body, g2)])
				},
			)
		}
	}
	Watch(k, i) => {
		v = val_of(g, i)
		plan = |x| [Title("t${x.to_str()}")]
		if k % 3 == 0 {
			Core.watch(v, plan, Core.ignore({}))
		} else if k % 3 == 1 {
			Core.watch_changes(v, plan, Core.ignore({}))
		} else {
			Core.watch_latest(v, plan, Core.ignore({}))
		}
	}
}

## What a `Pair`'s text and title begin with.
pair_mark : Str
pair_mark = "pair "

## Whether a title is a `Pair`'s and names a derived value that does not
## follow its layer: `pair x~d~y` with `d` other than `x * 2 + 1`.
unpaired : Str -> Bool
unpaired = |title|
	if title.starts_with(pair_mark) {
		match title.drop_prefix(pair_mark).split_on("~") {
			[x, d, ..] => (U64.from_str(d) ?? 0) != (U64.from_str(x) ?? 0) * 2 + 1
			_ => Bool.True
		}
	} else {
		Bool.False
	}

## Every input byte tripled: the one worker task's calculation.
triple : List(U8) -> List(U8)
triple = |bytes| bytes.map(|x| x.times_wrap(3))

## The one worker task, from bytes to bytes.
tripler : Worker.Task(Wire.Bytes, Wire.Bytes, Worker.Never)
tripler = Worker.task({ name: "roc-signals.test/structure/triple", run!: |bytes| Ok(Wire.Bytes.from_list(triple(bytes.to_list()))) })

## A job's answer as the walk gives it, with no worker to run it: what the
## task's entry gives after its file list, its output's bytes and the flag
## byte 0 for `Ok` (design.md, Appendix B, result tag 10).
tripled : List(U8) -> List(U8)
tripled = |input| {
	bytes : Wire.Bytes
	bytes = Wire.decode(input) ?? crash "structure: a job's input is not the task's"
	Wire.encode(Wire.Bytes.from_list(triple(bytes.to_list()))).append(0)
}

## A layer that follows a worker job for its input: the output's byte sum,
## or a marker for a lost or timed-out job.
job_cfg : { init : U64, pending : (U64, U64 -> U64), plan : (U64 -> List(Core.Request)), resolve : (U64, U64, Core.Result -> U64) }
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

# The typed levels. Below the root state (R1) layers nest three deep (R2 to
# R4). Each of the first three levels can hold rows (W1 to W3), and a row
# one layer of its own (V1 to V3). Past those, a body is drawn in place.

R1 : Core.In(Core.Root({}), U64)

R2 : Core.In(R1, U64)

R3 : Core.In(R2, U64)

R4 : Core.In(R3, U64)

W1 : Core.Row(R1, U64)

W2 : Core.Row(R2, U64)

W3 : Core.Row(R3, U64)

V1 : Core.In(W1, U64)

V2 : Core.In(W2, U64)

V3 : Core.In(W3, U64)

## The last level of any path: what nests below it is drawn in place.
bottom : List(Node), G(ctx) -> Core.Elem(ctx)
bottom = |ns, g| flat_list(ns, g, Bottom)

root_l2 : List(Node), G(R2) -> Core.Elem(R2)
root_l2 = |ns, g| flat_list(ns, g, Below({ layer: root_l3, row: row_2 }))

root_l3 : List(Node), G(R3) -> Core.Elem(R3)
root_l3 = |ns, g| flat_list(ns, g, Below({ layer: root_l4, row: row_3 }))

root_l4 : List(Node), G(R4) -> Core.Elem(R4)
root_l4 = |ns, g| flat_list(ns, g, Below({ layer: bottom, row: bottom }))

row_1 : List(Node), G(W1) -> Core.Elem(W1)
row_1 = |ns, g| flat_list(ns, g, Below({ layer: row_1_layer, row: bottom }))

row_1_layer : List(Node), G(V1) -> Core.Elem(V1)
row_1_layer = |ns, g| flat_list(ns, g, Below({ layer: bottom, row: bottom }))

row_2 : List(Node), G(W2) -> Core.Elem(W2)
row_2 = |ns, g| flat_list(ns, g, Below({ layer: row_2_layer, row: bottom }))

row_2_layer : List(Node), G(V2) -> Core.Elem(V2)
row_2_layer = |ns, g| flat_list(ns, g, Below({ layer: bottom, row: bottom }))

row_3 : List(Node), G(W3) -> Core.Elem(W3)
row_3 = |ns, g| flat_list(ns, g, Below({ layer: row_3_layer, row: bottom }))

row_3_layer : List(Node), G(V3) -> Core.Elem(V3)
row_3_layer = |ns, g| flat_list(ns, g, Below({ layer: bottom, row: bottom }))

## The page: the root state starting at `init`, then the tree.
view : List(Node), Bool, U64 -> Core.Elem(Core.Root({}))
view = |tree, pure, init| Core.state(
	init,
	|st| Core.element(
		"main",
		[],
		[
			show(st.signal()),
			Core.element("button", [Core.on_click(st.update(|x| x + 1))], [Core.text("+")]),
			flat_list(tree, { vals: [st.signal()], wrs: [st], pure }, Below({ layer: root_l2, row: row_1 })),
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
	absorb({ eng: a, dom: Dom.new({}), clicks: 0, jobs: [] }, a, c, "")
}

## Apply one batch to the oracle, keeping track of the worker jobs it issued
## or cancelled. `what` names the step the batch answers, or is "" for the
## mount: a step's batch must show no reader that saw the step half applied
## (`half_seen`).
absorb : S, Core.App, List(U8), Str -> S
absorb = |s, a, c, what| {
	{ dom, fx, written, .. } = Dom.apply_full(s.dom, c)
	if !what.is_empty() {
		turns = (Core.work_counters(a).get(turns_at) ?? 0) - (Core.work_counters(s.eng).get(turns_at) ?? 0)
		match half_seen(s.dom.nodes.len(), written, fx, turns) {
			Ok(_) => {}
			Err(why) => crash "${what}: ${why}"
		}
	}
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

## The index of the turns counter in the engine's work record (design.md,
## Appendix B).
turns_at : U64
turns_at = 30

## What in one step's batch shows a reader that saw the step half applied.
## `held` is how many nodes the oracle held before the batch, `written` the
## node each text or attribute command wrote, in order, and `turns` how many
## turns the call ran. A title is judged whatever the batch holds. The node
## rules are one turn's: a call that also delivers refusals queued behind
## the step runs a turn for each, and a later turn may write a node again.
half_seen : U64, List(U64), List(Dom.FxCmd), U64 -> Try({}, Str)
half_seen = |held, written, fx, turns| {
	for cmd in fx {
		match cmd {
			Title(title) =>
				if unpaired(title) {
					return Err("a watch was issued for \"${title}\", a derived value beside a layer it does not follow")
				}
			_ => {}
		}
	}
	if turns == 1 {
		var $seen = []
		for at in written {
			if at >= held {
				return Err("node ${at.to_str()} was created by the turn and then written again by it")
			}
			if $seen.contains(at) {
				return Err("node ${at.to_str()} was written twice in one turn")
			}
			$seen = $seen.append(at)
		}
	}
	Ok({})
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
				named = "${what} ${id.to_str()}"
				(absorb({ ..s, jobs: s.jobs.keep_if(|(j, _)| j != id) }, a, c, named), named)
			}
			Err(_) => (s, "no answer")
		}
	} else {
		cs = SpecRunner.candidates(s.dom)
		match cs.get(b % cs.len().max(1)) {
			Ok((i, ev)) =>
				match Dom.target(s.dom, i, ev, Bool.True) {
					Ok(target) => {
						(a, c) = Core.take_cmds(Core.event(s.eng, target.node, target.handler, ""), [])
						named = "click node ${target.node.to_str()}"
						(absorb({ ..s, clicks: s.clicks + 1 }, a, c, named), named)
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
			$x = SpecRunner.prng($x)
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
		# that exists only in the branch the `when` mounts second, written by
		# its own button and by a `Bump`.
		ex("late-state", 1, [1, 3, 0, 1, 0, 0, 1, 5, 0, 2, 0, 1, 2, 1], [0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 1]),
		# `Layer(state, 0, [Layer(state, 0, [Bump2(1, 2)])])`: one click
		# writes two nested states in one turn (issue #175).
		ex("two-writes", 1, [1, 5, 0, 1, 5, 0, 1, 12, 1, 2], [0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5]),
		# `Layer(state, 0, [Layer(state, 0, [Bump2(1, 2), Pair(2, 1), Pair(1, 2)])])`:
		# one click writes two nested states, and below both a text and a
		# watch read each with a derive of the other. Clicks 3 is the button
		# that writes both; 1 and 2 write one each; 0 the root.
		ex("pairs", 1, [1, 5, 0, 1, 5, 0, 3, 12, 1, 2, 10, 2, 1, 10, 1, 2], [0, 3, 0, 3, 0, 1, 0, 3, 0, 2, 0, 3, 0, 0, 0, 3]),
		ex("properties-in-rows", 0, [1, 7, 0, 1, 20, 0], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
		ex("series", 2, [], []),
	],
	generator: { mode: Fuzz.u8_in(0, 1), tree: Fuzz.list(Fuzz.u8, 80), events: Fuzz.list(Fuzz.u8, 80) }.Fuzz,
	test!,
	show: Str.inspect,
})
