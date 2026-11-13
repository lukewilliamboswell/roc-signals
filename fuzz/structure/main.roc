app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
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
##   Bump buttons also own size/seen observations; they follow the same
##   varied conditional, nested-layer and row lifetimes as their controls.
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
## - no reader sees an event half applied: a turn updates a node at most
##   once and never updates a node it created (ordinary constructor attributes
##   and properties initialize each field once), and every title a `Pair` sets
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
	Guard(U64),
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
			if b >= 100 {
				(Guard(i), d2)
			} else if b >= 20 {
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
		Ok(w) => Core.element("button", [Core.on_with("click", { prevent: i % 2 == 0, stop: i % 3 == 0 }, w.update(|n| n + 1)), Core.on_size(w.update(|value| value)), Core.on_seen({ ahead: i % 2 == 0 }, w.update(|value| value))], [Core.text("+")])
		Err(_) => Core.text("-")
	}

show : Core.Signal(ctx, U64) -> Core.Elem(ctx)
show = |v| Core.text_s(v.map(|n| n.to_str()))

flat_list : List(Node), G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat_list = |ns, g, inner| Core.element("div", [], ns.map(|n| flat(n, g, inner)))

flat : Node, G(ctx), Inner(ctx) -> Core.Elem(ctx)
flat = |n, g, inner| match n {
	Show(i) => show(val_of(g, i))
	Guard(i) => {
		flag = val_of(g, i).map(|value| value % 2 == 0)
		Core.element("span", [Core.attr_s("data-guard", flag.map(|on| if (on) "on" else "off"))], [Core.guard_leave(flag)])
	}
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
			# Generated document handlers live outside rows and are repeatedly
			# mounted/disposed by ordinary turns. Dom's independent detach check
			# rejects any missing RELEASE, including ancestor removal.
			Core.element(
				"aside",
				[],
				tree.map(
					|generated| Core.when(
						st.signal().map(|value| value % 2 == 0),
						|| Core.element(
							"span",
							[
								Core.on_document_key(
									{
										keymap: Core.const(
											Core.Keymap.keep([
												Core.Chord.plain(
													match generated {
														Show(_) => "Escape"
														_ => "F2"
													},
												),
											]),
										),
									},
									st.update(|value| value + 1),
								),
							],
							[],
						),
						|| Core.text(""),
					),
				),
			),
		],
	),
)

# ------------------------------------------------------------------- session

## The engine, the oracle's DOM, the clicks so far, and the worker jobs
## issued and not yet answered or cancelled (id and input).
S : { eng : Core.App, dom : Dom.Model, clicks : U64, jobs : List((U32, List(U8))), guard : Bool }

## Mount through the program's driver, so the worker catalogue is the one
## a host would see.
mount : List(Node), Bool, U64 -> S
mount = |tree, pure, init| {
	program = Core.program(|| view(tree, pure, init)).with_workers([tripler.registration()])
	(a, c, _) = (Core.driver(program).init)([])
	absorb({ eng: a, dom: Dom.new({}), clicks: 0, jobs: [], guard: False }, a, c, "")
}

## Apply one batch to the oracle, keeping track of the worker jobs it issued
## or cancelled. `what` names the step the batch answers, or is "" for the
## mount: a step's batch must show no reader that saw the step half applied
## (`half_seen`).
absorb : S, Core.App, List(U8), Str -> S
absorb = |s, a, c, what| {
	{ dom, fx, written } = batch_writes(s.dom, c)
	observed = Core.work_counters(a).get(44) ?? crash "structure: observation gauge is missing"
	if observed != dom.observed_count {
		crash "${what}: engine observation gauge ${observed.to_str()} differs from oracle ${dom.observed_count.to_str()}"
	}
	if (Core.work_counters(a).get(45) ?? 0) != dom.transitions.count {
		crash "${what}: engine transition count differs from the independent oracle"
	}
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
	guard = fx.fold(
		s.guard,
		|prior, command| match command {
			Guard(on) => on
			_ => prior
		},
	)
	if guard != guard_model(dom, dom.root) {
		crash "${what}: leave guard differs from live generated guards"
	}
	{ ..s, eng: a, dom, jobs, guard }
}

## Classify ordinary constructors separately from reader updates. ELEM does
## not carry attributes or properties, so its first ATTR per name and PROP
## per property initialize fields. A second setter for that same field is an
## update, even on a new node. TEXTNODE and INST already carry initial values,
## so their later text and hole setters are always updates. Keep Dom.written
## unchanged: the spec runner observes every write, including initialization.
batch_writes : Dom.Model, List(U8) -> { dom : Dom.Model, fx : List(Dom.FxCmd), written : List(U64) }
batch_writes = |before, bytes| {
	var $dom = before
	var $at = 0.U64
	var $fx = []
	var $written = []
	var $initialized = []
	var $ordinary = []
	while $at < bytes.len() {
		command_at = if ($at == 0) 1 else $at
		next_index = $dom.nodes.len()
		r = Dom.apply_next($dom, bytes, $at)
		op = r.ops.first() ?? 0
		if op == 8 {
			$ordinary = $ordinary.append(next_index)
		}
		for index in r.written {
			if $ordinary.contains(index) and (op == 9 or op == 21) {
				field = { index, kind: op, name: if (op == 9) Dom.str(bytes, command_at + 5).0 else Dom.byte(bytes, command_at + 5).to_str() }
				if $initialized.contains(field) {
					$written = $written.append(index)
				} else {
					$initialized = $initialized.append(field)
				}
			} else {
				$written = $written.append(index)
			}
		}
		$dom = r.dom
		$fx = $fx.concat(r.fx)
		$at = r.next
	}
	{ dom: $dom, fx: $fx, written: $written }
}

## The index of the turns counter in the engine's work record (design.md,
## Appendix B).
turns_at : U64
turns_at = 30

## What in one step's batch shows a reader that saw the step half applied.
## `held` is how many nodes the oracle held before the batch, `written` the
## node each reader update wrote after constructor classification, in order, and `turns` how many
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

## These generated operations are clicks. Key, size and seen listeners are
## still mounted and disposed for lifecycle coverage; they require typed
## payloads and are not click candidates.
click_candidates : Dom.Model -> List((U64, Str))
click_candidates = |dom| SpecRunner.candidates(dom).keep_if(|(_, event)| event == "click")

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
					Err(_) => (Fired(s.clicks.to_i64_wrap()), "fire timer")
				}
				(a, c) = Core.take_cmds(Core.result(s.eng, id, res), [])
				named = "${what} ${id.to_str()}"
				(absorb({ ..s, jobs: s.jobs.keep_if(|(j, _)| j != id) }, a, c, named), named)
			}
			Err(_) => (s, "no answer")
		}
	} else {
		cs = click_candidates(s.dom)
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

## One runner serves ordinary preflight expects and the compiled fuzz
## property's leak-checked region, so both replay the exact same histories.
run_input : Input -> {}
run_input = |{ mode, tree, events }| {
	if mode == 3 {
		observation_release_case({})
	} else if mode == 2 {
		series(11 + tree.len().to_u64(), 400)
	} else {
		run(decode(tree), mode == 0, events)
	}
}

test! : Input => Fuzz.Outcome
test! = |input| {
	Fuzz.expect_no_leaks!(|| run_input(input))
	Fuzz.keep
}

Case : { name : Str, input : Input }

ex : Str, U8, List(U8), List(U8) -> Case
ex = |name, mode, tree, events| { name, input: { mode, tree, events } }

fixed_cases : List(Case)
fixed_cases = [
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
	ex("guard-swaps-and-rows", 0, [3, 100, 0, 3, 0, 1, 100, 0, 1, 100, 0, 7, 0, 1, 100, 1], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
	ex("document-release", 0, [1, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0]),
	ex("clicks-with-observers", 0, [1, 2, 0], [0, 2, 0, 3, 0, 255, 0, 0]),
	ex("properties-in-late-branch", 0, [1, 3, 0, 0, 1, 20, 0], [0, 0, 0, 0]),
	ex("properties-in-rows", 0, [1, 7, 0, 1, 20, 0], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
	ex("observation-release", 3, [], []),
	ex("observations-in-rows", 0, [1, 7, 0, 1, 2, 0], [0, 0, 0, 0, 0, 0, 0, 0]),
	ex("series", 2, [], []),
]

## Every declared fixed history runs in the ordinary preflight as well.
## This catches an invalid generated event before an expensive LLVM build;
## the compiled fixed replay still checks the same history for leaks.
expect fixed_cases.map(|case| run_input(case.input)) == List.repeat({}, fixed_cases.len())

target = Fuzz.target_with!({
	name: "structure",
	examples: fixed_cases.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || case.input })),
	generator: { mode: Fuzz.u8_in(0, 1), tree: Fuzz.list(Fuzz.u8, 80), events: Fuzz.list(Fuzz.u8, 80) }.Fuzz,
	test!,
	show: Str.inspect,
})

## Ordinary root turns repeatedly dispose generated document shortcuts. The
## independent DOM oracle refuses any detached declaration without RELEASE.
expect run([Show(0), When(0, [Show(0)], [])], Bool.True, [0, 0, 0, 0, 0, 0, 0, 0]) == {}

## A branch owns both ordinary and template observations, including nested
## row state. Closing, reopening and closing it leaves no registration alive.
observation_release_case : {} -> {}
observation_release_case = |_props| {
	program = Core.program(
		|| Core.state(
			True,
			|visible| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(visible.update(|value| !value))], []),
					Core.when(
						visible.signal(),
						|| Core.element(
							"section",
							[Core.on_size(visible.update(|value| value))],
							[
								Core.each(
									Core.const([1.U64, 2]),
									|key| key.to_str(),
									|_row| Core.element(
										"article",
										[Core.on_size(visible.lift_row().update(|value| value)), Core.on_seen({ ahead: True }, visible.lift_row().update(|value| value))],
										[
											Core.state(0.U64, |local| Core.element("span", [Core.on_seen({}, local.update(|value| value))], [])),
										],
									),
								),
							],
						),
						|| Core.text(""),
					),
				],
			),
		),
	)
	(initial, commands, _) = (Core.driver(program).init)([])
	var $engine = initial
	var $dom = Dom.apply(Dom.new({}), commands)
	if $dom.observed_count != 7 or Core.work_counters($engine).get(44) != Ok(7) {
		crash "structure: initial observation count must be seven"
	}
	var $turn = 0.U64
	while $turn < 3 {
		button = Dom.find($dom, $dom.root, |n| n.tag == "button") ?? crash "structure: stable close control"
		listener = Dom.target($dom, button, "click", True) ?? crash "structure: stable close handler"
		(engine_after, emitted) = Core.take_cmds(Core.event($engine, listener.node, listener.handler, ""), [])
		$engine = engine_after
		$dom = Dom.apply($dom, emitted)
		want = if ($turn % 2 == 0) 0.U64 else 7
		if $dom.observed_count != want or Core.work_counters($engine).get(44) != Ok(want) {
			crash "structure: scope disposal or remount lost observation ownership"
		}
		$turn = $turn + 1
	}
	{}
}

## The independent oracle and the engine both reach zero after a nested
## observed branch, its template descendants and its row states are disposed.
expect observation_release_case({}) == {}

## The branch first mounts controls on a later turn. Their ordinary ATTR and
## PROP initialize fields rather than observing an earlier half-settled value.
expect {
	bytes = [1.U8, 3, 0, 0, 1, 20, 0]
	match decode(bytes) {
		[When(0, [], [Control(0)])] => run(decode(bytes), True, [0, 0, 0, 0]) == {}
		_ => False
	}
}

## Construction can set distinct ordinary fields once. Repeating an ATTR
## name or PROP kind remains a second reader write, including on a new node.
expect {
	element = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([8], 1), 0), 0), "input")
	attribute = |name, value| SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1), name).append(1), value)
	property = |kind, value| SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(kind), value)
	initial = [0].concat(element).concat(attribute("type", "text")).concat(attribute("aria-label", "Control")).concat(property(1, "first")).concat(property(2, "true"))
	check = |bytes| {
		r = batch_writes(Dom.new({}), bytes)
		half_seen(1, r.written, r.fx, 1)
	}
	{ initial: check(initial), attribute: check(initial.concat(attribute("type", "checkbox"))), property: check(initial.concat(property(1, "second"))) } == {
		initial: Ok({}),
		attribute: Err("node 1 was created by the turn and then written again by it"),
		property: Err("node 1 was created by the turn and then written again by it"),
	}
}

## TEXTNODE embeds its initial text; a later SETTEXT is an update. Existing
## nodes still reject two updates even when they name distinct properties.
expect {
	text = SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([0, 10], 1), 0), 0), "initial")
	update = SpecRunner.put_str(SpecRunner.put_u32([12], 1), "later")
	created = batch_writes(Dom.new({}), text.concat(update))
	(d, index) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "input" })
	dom = Dom.bind(d, 1, index)
	value = SpecRunner.put_str(SpecRunner.put_u32([0, 21], 1).append(1), "value")
	checked = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(2), "true")
	existing = batch_writes(dom, value.concat(checked))
	{ created: half_seen(1, created.written, created.fx, 1), existing: half_seen(dom.nodes.len(), existing.written, existing.fx, 1) } == {
		created: Err("node 1 was created by the turn and then written again by it"),
		existing: Err("node 1 was written twice in one turn"),
	}
}

## INST carries each hole's initial value. Its first later text, attribute
## or property setter is an update, even when addressed by an ordinary id.
expect {
	input = SpecRunner.put_str([1], "input").concat([0, 0])
	text = SpecRunner.put_str([2], "initial").concat([1, 1, 0])
	attribute = input.concat(SpecRunner.put_str([1, 2, 0], "aria-label"))
	property = input.concat([1, 6, 0, 1])
	row = SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([1], 1), 0), 0), 0)
	text_update = SpecRunner.put_str(SpecRunner.put_u32([2], 1).append(0), "later")
	attribute_update = SpecRunner.put_str(SpecRunner.put_u32([3], 1).concat([0, 1]), "later")
	property_update = SpecRunner.put_str(SpecRunner.put_u32([22], 1).append(0), "later")
	ordinary_property = SpecRunner.put_str(SpecRunner.put_u32([21], 1).append(1), "later")
	cases = [
		{ template: text, initial: SpecRunner.put_str(row, "initial"), update: text_update },
		{ template: attribute, initial: SpecRunner.put_str(row.append(1), "initial"), update: attribute_update },
		{ template: property, initial: SpecRunner.put_str(row, "initial"), update: property_update },
		{ template: property, initial: SpecRunner.put_str(row, "initial"), update: ordinary_property },
	]
	cases.map(
		|test| {
			define = SpecRunner.put_u32(SpecRunner.put_u32([0, 7], 0), test.template.len().to_u32_wrap()).concat(test.template)
			r = batch_writes(Dom.new({}), define.concat(test.initial).concat(test.update))
			half_seen(1, r.written, r.fx, 1)
		},
	) == List.repeat(Err("node 1 was created by the turn and then written again by it"), 4)
}

## The observer and document-key registrations are present, but this
## session supplies only clicks. Candidate choice never sends their typed
## handlers an empty click payload. Replay the exact former late-state case.
expect {
	held = mount([Bump(0)], True, 0)
	clicks = click_candidates(held.dom)
	clicks.len() == 2 and SpecRunner.candidates(held.dom).len() > clicks.len() and clicks.keep_if(|(_, event)| event != "click").is_empty() and run(decode([1, 3, 0, 1, 0, 0, 1, 5, 0, 2, 0, 1, 2, 1]), False, [0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 1]) == {}
}

## The model reads the target's independent rendered guard facts and their
## live structure. It shares no engine count or cached site Boolean.
guard_model : Dom.Model, U64 -> Bool
guard_model = |dom, index| {
	entry = Dom.node(dom, index)
	Dom.attr_of(entry, "data-guard") == "on" or entry.kids.any(|child| guard_model(dom, child))
}
