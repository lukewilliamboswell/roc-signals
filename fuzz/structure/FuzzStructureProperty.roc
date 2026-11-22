import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Engine
import pf.SpecRunner
import pf.WorkerCodec
import pf.Wire
import pf.Worker
import Reference
import Vectors

## Generated structure: bytes decode into a site tree and a session over it,
## so the engine meets nestings no fixed app happens to contain.
##
## The tree is at most 5 deep and 40 nodes, over every site kind
## (`Reference.Node` says what each node draws); the only awaited requests
## are timers and worker jobs:
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
## - `When(sel, yes, no)` on the parity of what `sel` selects and
##   `Switch(sel, a, b, c)` on it modulo 3, where `sel` reads one layer or
##   two together (`Sel`);
## - `Layer(kind, i, body)`: a `state`, a `derive` of a layer (`2x + 1`, or
##   `x // 2`, which can leave its value unchanged), a `resource` whose
##   `pending` follows its input, a `resource` that issues a timer and
##   counts its answers, or a `resource` that issues a worker job for its
##   input and folds its output, its loss or its timeout; each shows its own
##   value and a `state` gets a button of its own;
## - `Each(sel, body)`: the rows `Reference.rows_of` gives for what `sel`
##   selects, keyed by a key that leaves and comes back as the value moves
##   and holding an item that changes under a kept key; each row a `div`
##   showing `key:item` and holding `body`. Rows nest in rows, and an `li`
##   row would not: through the `div` of a layer between them, the HTML
##   parser closes the outer `li` at the inner one, which mount refuses;
## - `Watch(k, i)`: a `watch`, `on_change` or `latest` that sets the title.
##
## Indices count from the start below 128 and from the end at 128 and above
## (`Reference.place`). The decoder is biased toward one shape bytes alone
## rarely build (`two_writes`): a button writing the root and a state below
## it, with a structural reader of both below them, one through a derived
## value, holding state.
##
## The contexts a tree can nest through are typed by hand (the generator's
## levels): three layers below the root state, a row at each of the first
## three levels, and one layer inside a row. Below the last level a `Layer`
## or an `Each` draws its body in place and adds no scope. That keeps the
## generator monomorphic: a recursive generator over the typed contexts
## would need polymorphic recursion, which the compiler rejects. So the
## levels cannot express a scope five deep below the root's (a layer or a
## row at the last level), any scope inside a row that is itself inside a
## row, or a third scope inside a row; a generated shape that needs one is
## drawn in place, and `Reference` draws it in place too.
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
## - in the valued modes (4, one session; 5, a seeded series) every state
##   is written, resources issue nothing and the session only clicks, so the
##   page is a function of the tree and the local states alive: after every
##   click its texts and its click candidates must be those `Reference.page`
##   draws from scratch for the states `Reference.clicked` holds. A kept
##   scope whose state the engine started again, a state carried across a
##   removal, or a reader that settled on one new value beside one old one
##   shows up as a different text. The series' shape shares are held to
##   minimums (`valued_tally`);
## - in mode 6 the program and clicks of one vector Lean wrote
##   (`Vectors`) run as a valued session, so the engine meets every tree the
##   value model is held to;
## - the session frees everything it allocated.

Node : Reference.Node

Sel : Reference.Sel

Row : Reference.Row

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
			(sel, d3) = selector(b, i, d2)
			(yes, d4) = nodes(d3, depth)
			(no, d5) = nodes(d4, depth)
			(When(sel, yes, no), d5)
		}
		4 => {
			(sel, d3) = selector(b, i, d2)
			(a, d4) = nodes(d3, depth)
			(c1, d5) = nodes(d4, depth)
			(c2, d6) = nodes(d5, depth)
			(Switch(sel, a, c1, c2), d6)
		}
		5 | 6 => {
			(body, d3) = nodes(d2, depth)
			(Layer(b // 10, i, body), d3)
		}
		7 | 8 => {
			(sel, d3) = selector(b, i, d2)
			(body, d4) = nodes(d3, depth)
			(Each(sel, body), d4)
		}
		_ =>
			if b >= 100 {
				two_writes(i, d2, depth)
			} else {
				(Watch(b // 10, i), d2)
			}
	}
}

## A structural reader's selector: two values when the tens digit of its
## node byte is odd, else one.
selector : U64, U64, Reader -> (Sel, Reader)
selector = |b, i, d|
	if (b // 10) % 2 == 1 {
		(j, d2) = next(d)
		(Two(i, j), d2)
	} else {
		(One(i), d)
	}

## A shape the generator is biased toward, since bytes alone rarely build
## it: one button writes the root state and a state below it, and below
## both a structural reader follows both writes, one through a derived
## value, with a state in each branch or row that the session can move away
## from 0. Two passes, in either order, would show that reader one new
## value beside one old one and dispose and remount what it holds.
##
## `v` picks the shape. With `v % 2 == 0` the derived value is between the
## two writes (a `derive` or a `resource` of the root, or the item of a row
## keyed by the root), so it follows the outer write; otherwise it is a
## `derive` of the inner state, below it. `(v // 2) % 3` picks the reader: a
## `when`, a `switch` or an `each`. Indices count from the end (128 is the
## nearest value or state, `Reference.place`); index 0 is the root. The
## nodes after the reader are decoded from the bytes that follow.
two_writes : U64, Reader, U64 -> (Node, Reader)
two_writes = |v, d0, depth| {
	(rest, d1) = nodes({ ..d0, left: d0.left - d0.left.min(6) }, depth)
	held = [Layer(0, 0, [])]
	reader = |sel| match (v // 2) % 3 {
		0 => When(sel, held, held)
		1 => Switch(sel, held, held, held)
		_ => Each(sel, held)
	}
	if v % 2 == 0 {
		inner = Layer(0, 0, [Bump2(0, 128), reader(Two(129, 128))].concat(rest))
		outer = match (v // 6) % 3 {
			0 => Layer(1, 0, [inner])
			1 => Layer(2, 0, [inner])
			_ => Each(One(0), [inner])
		}
		(outer, d1)
	} else {
		(Layer(0, 0, [Layer(1, 128, [Bump2(0, 128), reader(Two(0, 128))].concat(rest))]), d1)
	}
}

decode : List(U8) -> List(Node)
decode = |bytes| nodes({ bytes, pos: 0, left: 40 }, 5).0

# ---------------------------------------------------------------- generating

## What a node can read and write where it is built. `pure`: writes go to the
## root only and resources issue nothing (mode 0). `valued`: every state is
## written and resources issue nothing (modes 4 and 5, checked against
## `Reference.page`).
G(ctx) : { vals : List(Core.Signal(ctx, U64)), wrs : List(Core.State(ctx, U64)), pure : Bool, valued : Bool }

## How to build what nests below a layer and inside a row, at a level that
## has typed levels below it; at the bottom, a layer's or a row's body is
## drawn in place.
Inner(ctx) : [
	Below({ layer : (List(Node), G(Core.In(ctx, U64)) -> Core.Elem(Core.In(ctx, U64))), row : (List(Node), G(Core.Row(ctx, Row)) -> Core.Elem(Core.Row(ctx, Row))) }),
	Bottom,
]

val_of : G(ctx), U64 -> Core.Signal(ctx, U64)
val_of = |g, i| Reference.pick(g.vals, i, Core.const(0))

## The writable state `i` names (`Reference.place`).
wr_of : G(ctx), U64 -> Try(Core.State(ctx, U64), [Nothing])
wr_of = |g, i| match g.wrs.get(Reference.place(g.wrs.len(), i)) {
	Ok(w) => Ok(w)
	Err(_) => Err(Nothing)
}

## What a `when`, a `switch` or an `each` follows: one signal, or two read
## together as their sum.
chosen : G(ctx), Sel -> Core.Signal(ctx, U64)
chosen = |g, sel| match sel {
	One(i) => val_of(g, i)
	Two(i, j) => val_of(g, i).map2(val_of(g, j), |x, y| x + y)
}

## A button whose click adds 1 to writable `i` (none when nothing is
## writable).
bump_button : G(ctx), U64 -> Core.Elem(ctx)
bump_button = |g, i|
	match wr_of(g, i) {
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
		match (wr_of(g, i), wr_of(g, j)) {
			(Ok(first), Ok(second)) if !g.pure => Core.element("button", [Core.on("click", first.update(|x| x + 1).also(second.update(|x| x + 1)))], [Core.text("++")])
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
				Core.element("p", [], [Core.text_s(seen), Core.watch(seen, |text| [Core.command(Title(text))], Core.ignore({}))])
			},
		)
	}
	When(sel, yes, no) => Core.when(chosen(g, sel).map(|x| x % 2 == 0), || flat_list(yes, g, inner), || flat_list(no, g, inner))
	Switch(sel, a, b, c) => Core.switch(chosen(g, sel).map(|x| x % 3), [0, 1, 2], |k| flat_list(if (k == 0) a else if (k == 1) b else c, g, inner))
	Layer(kind, i, body) => match inner {
		Bottom => flat_list(body, g, Bottom)
		Below({ layer, .. }) => {
			v = val_of(g, i)
			lifted = g.vals.map(|x| x.lift())
			lwrs = g.wrs.map(|w| w.lift())
			pure = g.pure
			valued = g.valued
			k = kind % 5
			if k == 0 {
				Core.state(
					0.U64,
					|st| {
						own = if (pure) [] else [Core.element("button", [Core.on("click", st.update(|x| x + 1))], [Core.text("+")])]
						g2 = { vals: lifted.append(st.signal()), wrs: if (pure) lwrs else lwrs.append(st), pure, valued }
						Core.element("div", [], [show(st.signal())].concat(own).append(layer(body, g2)))
					},
				)
			} else if k == 1 {
				Core.derive(v.map(|x| Reference.derived(kind, x)), |d| Core.element("div", [], [show(d), layer(body, { vals: lifted.append(d), wrs: lwrs, pure, valued })]))
			} else if k == 2 or pure or valued {
				Core.resource(v, { init: 0.U64, pending: |_, a| a + 7, plan: |_| [], resolve: |s, _, _| s }, |r| Core.element("div", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure, valued })]))
			} else if k == 3 {
				Core.resource(v, { init: 0.U64, pending: |_, a| a * 10, plan: |_| [Core.timer(10)], resolve: |s, _, _| s + 1 }, |r| Core.element("div", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure, valued })]))
			} else {
				Core.resource(v, job_cfg, |r| Core.element("div", [], [show(r), layer(body, { vals: lifted.append(r), wrs: lwrs, pure, valued })]))
			}
		}
	}
	Each(sel, body) => match inner {
		Bottom => flat_list(body, g, Bottom)
		Below({ row, .. }) => {
			rows = chosen(g, sel).map(Reference.rows_of)
			vals = g.vals
			wrs = g.wrs
			pure = g.pure
			valued = g.valued
			Core.each(
				rows,
				|each_row| each_row.key.to_str(),
				|r| {
					item = r.field(|each_row| each_row.item)
					label = r.field(|each_row| "${each_row.key.to_str()}:${each_row.item.to_str()}")
					g2 = { vals: vals.map(|x| x.lift_row()).append(item), wrs: wrs.map(|w| w.lift_row()), pure, valued }
					Core.element("div", [], [Core.text_s(label), row(body, g2)])
				},
			)
		}
	}
	Watch(k, i) => {
		v = val_of(g, i)
		plan = |x| [Core.command(Title("t${x.to_str()}"))]
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
	bytes = WorkerCodec.decode(input) ?? crash "structure: a job's input is not the task's"
	WorkerCodec.encode(Wire.Bytes.from_list(triple(bytes.to_list()))).append(0)
}

## A layer that follows a worker job for its input: the output's byte sum,
## or a marker for a lost or timed-out job.
raw_result : Try(Core.Result, []) -> Core.Result
raw_result = |answer| match answer {
	Ok(result) => result
}

job_cfg : { init : U64, pending : (U64, U64 -> U64), plan : (U64 -> List(Core.Ask(Core.Result, []))), resolve : (U64, U64, Try(Core.Result, []) -> U64) }
job_cfg = {
	init: 0,
	pending: |_, a| a + 3,
	plan: |a| [Core.raw(tripler.request(Wire.Bytes.from_list([a.to_u8_wrap(), 1])))],
	resolve: |s, _, raw| match raw_result(raw) {
		Work(_) =>
			match tripler.result(raw_result(raw)) {
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

W1 : Core.Row(R1, Row)

W2 : Core.Row(R2, Row)

W3 : Core.Row(R3, Row)

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
view : List(Node), Bool, Bool, U64 -> Core.Elem(Core.Root({}))
view = |tree, pure, valued, init| Core.state(
	init,
	|st| Core.element(
		"main",
		[],
		[
			show(st.signal()),
			Core.element("button", [Core.on("click", st.update(|x| x + 1))], [Core.text("+")]),
			flat_list(tree, { vals: [st.signal()], wrs: [st], pure, valued }, Below({ layer: root_l2, row: row_1 })),
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
S : { eng : Core.App({}), dom : Dom.Model, clicks : U64, jobs : List((U32, List(U8))), guard : Bool }

## Mount through the program's driver, so the worker catalogue is the one
## a host would see.
mount : List(Node), Bool, U64 -> S
mount = |tree, pure, init| mount_as(tree, pure, False, init)

## `mount`, in valued mode when `valued`.
mount_as : List(Node), Bool, Bool, U64 -> S
mount_as = |tree, pure, valued, init| {
	program = Core.program(|| view(tree, pure, valued, init)).with_workers([tripler.registration()])
	(a, c, _) = (Core.driver(program).init)([])
	absorb({ eng: a, dom: Dom.new({}), clicks: 0, jobs: [], guard: False }, a, c, "")
}

## Apply one batch to the oracle, keeping track of the worker jobs it issued
## or cancelled. `what` names the step the batch answers, or is "" for the
## mount: a step's batch must show no reader that saw the step half applied
## (`half_seen`).
absorb : S, Core.App({}), List(U8), Str -> S
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
				field = {
					index,
					field: if op == 9 {
						expanded = Dom.expanded_name(bytes, command_at + 5, False).0
						Attribute({ namespace: expanded.namespace, local: expanded.local })
					} else Property(Dom.byte(bytes, command_at + 5)),
				}
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

## Fresh comparison uses the renderer's one model walk. Attribute order is
## ignored only here; canonical picture data keeps the original order. Logical
## text partitions remain observable even when HTML merges the physical run.
render : Dom.Model, U64 -> Str
render = |dom, i| {
	picture = Dom.render(dom, { root: i, limits: { max_bytes: 16_777_216, max_nodes: 262_144, max_depth: 1024 } }) ?? crash "structure diagnostic render exceeded its explicit bounds"
	physical = picture.physical.map(
		|physical_node| match physical_node {
			Element(element) => Element({ ..element, attributes: element.attributes.sort_with(|(left, _), (right, _)| compare_bytes(Str.inspect(left).to_utf8(), Str.inspect(right).to_utf8())) })
			other => other
		},
	)
	Str.inspect({ physical, containers: picture.containers, logical: picture.logical.map(|logical| logical.target), text_runs: picture.text_runs, scaffolds: picture.scaffolds })
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
		Err({ cmds, note }) => crash "${what}: a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(s.dom, [0].concat(cmds)).1)} ${note}"
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

# ---------------------------------------------------------- the value model

# Modes 4 and 5 (valued): every state is written by clicks and nothing is
# awaited, so the page is a function of the tree and of the local states
# that are alive. `Reference.page` is that function, written from each
# node's meaning and from nothing in the engine.

## What the comparison reads of the oracle's DOM: every text node that is
## not empty, in document order. Wrapper elements, attributes, properties
## and the order among nodes that are not text are left out, so the
## comparison does not depend on how `flat` nests its `div`s, and it cannot
## see a wrong attribute, a wrong property or a misplaced element without
## text.
page_texts : Dom.Model, U64 -> List(Str)
page_texts = |dom, index| {
	entry = Dom.node(dom, index)
	if entry.kind == 2 {
		if (entry.text.is_empty()) [] else [entry.text]
	} else if entry.kind == 3 {
		[]
	} else {
		entry.kids.fold([], |acc, kid| acc.concat(page_texts(dom, kid)))
	}
}

## The page the engine drew must show the texts the model draws from
## scratch, button labels included, in document order, and offer as many
## click candidates as the model has buttons (the model's buttons are the
## page's click candidates, in the same order, so the session clicks the
## same button in both).
agree : S, List(Node), Reference.Held, Str -> {}
agree = |s, tree, held, what| {
	want = Reference.page(tree, held)
	got = page_texts(s.dom, s.dom.root)
	if got != Reference.texts(want) {
		crash "${what}: the page differs from the value model:\n  engine ${Str.inspect(got)}\n  model  ${Str.inspect(Reference.texts(want))}\n  states ${Str.inspect(held)}"
	}
	if click_candidates(s.dom).len() != Reference.buttons(want) {
		crash "${what}: the page offers ${click_candidates(s.dom).len().to_str()} buttons, the value model ${Reference.buttons(want).to_str()}"
	}
	{}
}

## Mode 4: a session of clicks, each compared with the value model. Every
## second event byte chooses the button; the first is the op byte of the
## other modes and is not read, since valued mode only clicks.
run_valued : List(Node), List(U8) -> Reference.Tally
run_valued = |tree, events| {
	var $s = settle_check(mount_as(tree, False, True, 0), "mount")
	var $seen = Reference.start
	var $tally = Reference.no_tally
	agree($s, tree, $seen.held, "mount")
	var $i = 0.U64
	while $i + 1 < events.len() {
		b = (events.get($i + 1) ?? 0).to_u64()
		k = b % Reference.buttons(Reference.page(tree, $seen.held)).max(1)
		(s1, what0) = step($s, 0, b)
		what = "valued step ${($i // 2).to_str()} (${what0}, button ${k.to_str()})"
		$s = settle_check(s1, what)
		r = Reference.click(tree, $seen, k)
		$seen = r.seen
		agree($s, tree, $seen.held, what)
		$tally = Reference.add($tally, r.tally)
		$i = $i + 2
	}
	$tally
}

## The trees and click bytes of the seeded valued series: `count` inputs of
## 160 bytes from `seed`, the first 80 a tree and every second byte of the
## rest a click (`run_valued`).
valued_inputs : U64, U64 -> List({ tree : List(Node), events : List(U8) })
valued_inputs = |seed, count| {
	var $x = seed
	var $k = 0.U64
	var $out = []
	while $k < count {
		var $bytes = []
		var $j = 0.U64
		while $j < 160 {
			$x = SpecRunner.prng($x)
			$bytes = $bytes.append($x.shr_zf_wrap(40).to_u8_wrap())
			$j = $j + 1
		}
		$out = $out.append({ tree: decode($bytes.take_first(80)), events: $bytes.drop_first(80) })
		$k = $k + 1
	}
	$out
}

## The seed and length of the valued series (mode 5).
valued_seed : U64
valued_seed = 17

valued_count : U64
valued_count = 400

## Mode 5: the seeded valued series, each session against the engine.
valued_series : U64, U64 -> Reference.Tally
valued_series = |seed, count| valued_inputs(seed, count).fold(Reference.no_tally, |tally, input| Reference.add(tally, run_valued(input.tree, input.events)))

## The same series in the model alone: what it exercises, with no engine.
valued_tally : U64, U64 -> Reference.Tally
valued_tally = |seed, count| valued_inputs(seed, count).fold(
	Reference.no_tally,
	|tally, input| {
		var $clicks = []
		var $i = 1.U64
		while $i < input.events.len() {
			$clicks = $clicks.append(input.events.get($i) ?? 0)
			$i = $i + 2
		}
		Reference.add(tally, Reference.session(input.tree, $clicks))
	},
)

## The same arbitrary shape also builds a tree containing only fixed text
## and attributes. Its independent preorder model checks every title and text;
## zero sampled evaluations proves constants did not become dynamic holes.
constant_caption : Node -> Str
constant_caption = |branch| match branch {
	Show(index) => "show-${index.to_str()}"
	Guard(index) => "guard-${index.to_str()}"
	Control(index) => "control-${index.to_str()}"
	Bump(index) => "bump-${index.to_str()}"
	Bump2(left, right) => "bump-${left.to_str()}-${right.to_str()}"
	Pair(left, right) => "pair-${left.to_str()}-${right.to_str()}"
	When(sel, _, _) => "when-${sel_caption(sel)}"
	Switch(sel, _, _, _) => "switch-${sel_caption(sel)}"
	Layer(kind, index, _) => "layer-${kind.to_str()}-${index.to_str()}"
	Each(sel, _) => "each-${sel_caption(sel)}"
	Watch(kind, index) => "watch-${kind.to_str()}-${index.to_str()}"
}

sel_caption : Sel -> Str
sel_caption = |sel| match sel {
	One(index) => index.to_str()
	Two(left, right) => "${left.to_str()}+${right.to_str()}"
}

constant_elements : List(Node) -> List(Engine.Elem(Engine.Root))
constant_elements = |tree| tree.map(
	|branch| {
		children = match branch {
			When(_, yes, no) => constant_elements(yes).concat(constant_elements(no))
			Switch(_, first, second, third) => constant_elements(first).concat(constant_elements(second)).concat(constant_elements(third))
			Layer(_, _, body) | Each(_, body) => constant_elements(body)
			_ => []
		}
		caption = constant_caption(branch)
		Engine.element("div", [Engine.attr_s("title", Engine.const(caption)), Engine.class_s("constant"), Engine.test_id_s("static-${Engine.const(caption)}")], [Engine.text_s("text ${Engine.const(caption)}")].concat(children))
	},
)

## Walk the generated data, not the mounted engine, to obtain expected
## preorder labels. Conditional branches are ordinary static children here.
constant_labels : List(Node) -> List(Str)
constant_labels = |tree| {
	var $labels = []
	for branch in tree {
		$labels = $labels.append(constant_caption(branch))
		match branch {
			When(_, yes, no) => {
				$labels = $labels.concat(constant_labels(yes)).concat(constant_labels(no))
			}
			Switch(_, first, second, third) => {
				$labels = $labels.concat(constant_labels(first)).concat(constant_labels(second)).concat(constant_labels(third))
			}
			Layer(_, _, body) | Each(_, body) => {
				$labels = $labels.concat(constant_labels(body))
			}
			_ => {}
		}
	}
	$labels
}

constant_tree_property : List(Node) -> {}
constant_tree_property = |tree| {
	(engine, batch) = Core.take_cmds(Core.mount(Engine.element("main", [], constant_elements(tree))), [])
	dom = Dom.apply(Dom.new({}), batch)
	labels = constant_labels(tree)
	actual = { labels: dom.nodes.keep_if(|branch| branch.tag == "div").map(|branch| Dom.attr_of(branch, "title")), text: Dom.text_of(dom, dom.root), evaluations: Core.evals(engine) }
	wanted = { labels, text: Str.join_with(labels.map(|label| "text ${label}"), ""), evaluations: 0.U64 }
	if actual != wanted {
		crash "constant text tree differs: ${Str.inspect(actual)} expected ${Str.inspect(wanted)}"
	}
	if Core.settled(engine).is_err() {
		crash "constant text tree is not settled"
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

## The valued series reaches the shapes that expose an event's writes
## settled out of order or a kept row's state lost, in shares of its clicks
## at least half of those at which it found both by hand (the inner-first
## two-pass bug and a kept row reset on a list change): clicks writing two
## states one structural reader follows, of which some through a derived
## value; clicks disposing a state that was not at 0; rows drawn again after
## a removal; and kept rows whose item changed.
expect {
	t = valued_tally(valued_seed, valued_count)
	{
		both_read: t.both_read * 1000 >= t.clicks * 15,
		through_derived: t.through_derived * 1000 >= t.clicks * 15,
		disposed_live: t.disposed_live * 1000 >= t.clicks * 20,
		reinserted: t.reinserted * 10 >= t.clicks * 10,
		kept_changed: t.kept_changed * 10 >= t.clicks * 4,
	} == { both_read: True, through_derived: True, disposed_live: True, reinserted: True, kept_changed: True }
}

## One runner serves ordinary preflight expects and the compiled fuzz
## property's leak-checked region, so both replay the exact same histories.
run_input : Input -> {}
run_input = |{ mode, tree, events }| {
	unsafe_html_history(events)
	constant_tree_property(decode(tree))
	if mode == 5 {
		_tally = valued_series(valued_seed + tree.len().to_u64(), valued_count)
		{}
	} else if mode == 4 {
		_tally = run_valued(decode(tree), events)
		{}
	} else if mode == 6 {
		# A declared example names its vector by index; an explored input
		# may name any number, so it replays the vector its first byte names,
		# counted round the file.
		at = (tree.first() ?? 0).to_u64() % Vectors.good.len()
		vector = Vectors.good.get(at) ?? crash "structure: the vector file is empty"
		_tally = run_valued(vector.tree, Vectors.clicks(vector))
		{}
	} else if mode == 3 {
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
	ex("opaque-html-updates-moves-and-disposal", 0, [], [0, 1, 2, 3, 0, 3, 2, 0, 1, 0, 0, 0]),
	ex("constant-text-and-attributes", 0, [3, 5, 0, 1, 0, 0, 7, 0, 1, 0, 0, 3, 0, 1, 0, 0, 1, 0, 1], []),
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
	ex("valued-series", 5, [], []),
	# `Layer(state A, [Layer(state B, [When(Two(A, B), [Layer(state C, [])], []), Bump2(A, B)])])`:
	# a `when` on the parity of two states one click writes together. The
	# sum's parity is unchanged, so the branch and its state must be kept;
	# a selector read between the two writes would dispose and remount it.
	ex("valued-when-of-two-writes", 4, [1, 5, 0, 1, 5, 0, 2, 13, 1, 2, 1, 5, 0, 0, 0, 12, 1, 2], [0, 3, 0, 3, 0, 4, 0, 1, 0, 1, 0, 3, 0, 4]),
	# The same with an `each` whose rows follow A + B and hold a state each.
	ex("valued-rows-of-two-writes", 4, [1, 5, 0, 1, 5, 0, 2, 17, 1, 2, 1, 5, 0, 0, 12, 1, 2], [0, 3, 0, 3, 0, 4, 0, 1, 0, 3, 0, 5, 0, 7, 0, 6]),
	# `Layer(derive D = 2R + 1, [Layer(state B, [Each(Two(D, B), [Layer(state C, [])]), Bump2(R, B)])])`:
	# rows follow a `derive` of the root and a state below it, and one
	# click writes both. A pass for B before the root's would draw the rows
	# for the new B beside the old D, dropping rows the click keeps.
	ex("valued-rows-of-outer-derive", 4, [1, 15, 0, 1, 5, 0, 2, 17, 1, 2, 1, 5, 0, 0, 12, 0, 1], [0, 3, 0, 3, 0, 2, 0, 5, 0, 4, 0, 6, 0, 2]),
	# `Layer(state B, [Layer(derive D = 2B + 1, [Each(Two(R, D), [Layer(state C, [])]), Bump2(R, B)])])`:
	# rows follow the root and a `derive` of a state above them. A pass for
	# the root before B's would draw the rows for the new root beside the
	# old D.
	ex("valued-rows-of-inner-derive", 4, [1, 5, 0, 1, 15, 1, 2, 17, 0, 2, 1, 5, 0, 0, 12, 0, 1], [0, 3, 0, 3, 0, 2, 0, 5, 0, 4, 0, 6, 0, 2]),
	# `Layer(derive D = 2R + 1, [Layer(state B, [Switch(Two(D, B), [C], [C], [C]), Bump2(R, B)])])`,
	# each case holding a state C: the click adds 3 to D + B, so the case
	# and its state are kept. With B's pass first (inner first) the case
	# moves on and back, and C starts again at 0.
	ex("valued-switch-of-outer-derive", 4, [1, 15, 0, 1, 5, 0, 2, 14, 1, 2, 1, 5, 0, 0, 1, 5, 0, 0, 1, 5, 0, 0, 12, 0, 1], [0, 2, 0, 2, 0, 3, 0, 2, 0, 3]),
	# `Layer(state B, [Layer(derive D = 2B + 1, [Switch(Two(R, D), [C], [C], [C]), Bump2(R, B)])])`:
	# the same with the derived value below the inner write. With the
	# root's pass first (outer first) the case moves on and back.
	# `When(One(R), [Each(One(R), [])], [Layer(resource of R, [Layer(state B, [Layer(derive of B, [Bump2(R, B)])])])])`:
	# the click writes the root and B, the root's pass leaves the branch
	# that holds B for the one with the rows, and the walk for B, which
	# waited, must not follow the event's path into the new branch.
	ex("valued-walk-into-remounted-branch", 4, [1, 3, 0, 1, 7, 0, 0, 1, 25, 0, 1, 5, 0, 1, 15, 128, 1, 12, 0, 128], [0, 0, 0, 2]),
	# `Layer(derive H = R // 2, [Show(H), Bump(R)])`: every second click
	# leaves the halved value as it was, and its readers must not move.
	ex("valued-halving-derive", 4, [1, 65, 0, 2, 0, 128, 2, 0], [0, 0, 0, 0, 0, 0, 0, 0]),
	ex("valued-switch-of-inner-derive", 4, [1, 5, 0, 1, 15, 1, 2, 14, 0, 2, 1, 5, 0, 0, 1, 5, 0, 0, 1, 5, 0, 0, 12, 0, 1], [0, 2, 0, 2, 0, 3, 0, 2, 0, 3]),
].concat(
	# Mode 6: the programs and clicks of `vectors.trace`, through the engine.
	Vectors.good.map_with_index(|vector, at| ex("vector-${vector.name}", 6, [at.to_u8_wrap()], [])),
)

## Every declared fixed history runs in the ordinary preflight as well.
## This catches an invalid generated event before an expensive LLVM build;
## the compiled fixed replay still checks the same history for leaks.
expect fixed_cases.map(|case| run_input(case.input)) == List.repeat({}, fixed_cases.len())

fuzz_target = Fuzz.target_with!({
	name: "structure",
	examples: fixed_cases.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || case.input })),
	generator: { mode: Fuzz.map(Fuzz.u8_in(0, 2), |m| if (m == 2) 4 else m), tree: Fuzz.list(Fuzz.u8, 80), events: Fuzz.list(Fuzz.u8, 80) }.Fuzz,
	test!,
	show: Str.inspect,
})

## Ordinary root turns repeatedly dispose generated document shortcuts. The
## independent DOM oracle refuses any detached declaration without RELEASE.
expect run([Show(0), When(One(0), [Show(0)], [])], Bool.True, [0, 0, 0, 0, 0, 0, 0, 0]) == {}

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
					Core.element("button", [Core.on("click", visible.update(|value| !value))], []),
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
		[When(One(0), [], [Control(0)])] => run(decode(bytes), True, [0, 0, 0, 0]) == {}
		_ => False
	}
}

## Construction can set distinct ordinary fields once. Repeating an ATTR
## name or PROP kind remains a second reader write, including on a new node.
expect {
	element = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([8], 1), 0), 0).append(0), ""), "input").append(0)
	attribute = |name, value| SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1).append(3), ""), name).append(1), value)
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
	input = SpecRunner.put_str(SpecRunner.put_str([1, 0], ""), "input").concat([0, 0, 0])
	text = SpecRunner.put_str([2], "initial").concat([1, 1, 0])
	attribute = input.concat(SpecRunner.put_str(SpecRunner.put_str([1, 2, 0, 3], ""), "aria-label"))
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

## Attribute initialization identity is URI plus local name, independent of
## framing code and prefix. Equal-length different names remain separate fields.
expect {
	element = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32(SpecRunner.put_u32(SpecRunner.put_u32([0, 8], 1), 0), 0).append(0), ""), "div").append(0)
	ordinary = |name| SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1).append(3), ""), name).append(1), "value")
	builtin = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1).append(0), "a"), "key").append(1), "before")
	alias = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u32([9], 1).append(4), "http://www.w3.org/1999/xhtml"), "b"), "key").append(1), "after")
	classify = |bytes| {
		result = batch_writes(Dom.new({}), bytes)
		half_seen(1, result.written, result.fx, 1)
	}
	classify(element.concat(ordinary("data-aa")).concat(ordinary("data-bb"))) == Ok({}) and classify(element.concat(builtin).concat(alias)) == Err("node 1 was created by the turn and then written again by it")
}

HtmlHistory : { content : U64, visible : Bool, reversed : Bool }

## A bounded HTML vocabulary deliberately includes source browsers repair or
## execute. The oracle must retain every byte without interpreting that source.
history_html : U64 -> Str
history_html = |choice| ["", "<h2>one</h2>", "<table><tr><td>two", "<script>raw()</script>", "<a href='javascript:raw()'>three</a>"].get(choice % 5) ?? crash "bounded HTML vocabulary"

history_after : HtmlHistory, U8 -> HtmlHistory
history_after = |before, operation| match operation % 4 {
	0 => { ..before, content: before.content + 1 }
	1 => before
	2 => { ..before, reversed: !before.reversed }
	_ => { ..before, visible: !before.visible }
}

history_view : HtmlHistory -> Core.Elem(Core.Root({}))
history_view = |initial| Core.state(
	initial,
	|state| Core.element(
		"main",
		[],
		[
			Core.element("button", [Core.on("click", state.set_value(|before, payload| history_after(before, U8.from_str(payload) ?? crash "generated operation")))], [Core.text("advance")]),
			Core.when(state.signal().map(|value| value.visible), || Core.unsafe_html("section", [], Core.attr_s("title", state.signal().map(|value| history_html(value.content)))), || Core.text("")),
			Core.each(state.signal().map(|value| if (value.reversed) ["b", "a"] else ["a", "b"]), |key| key, |row| Core.unsafe_html("article", [], Core.attr_s("title", row.key().map2(state.signal().lift_row(), |key, value| "${key}:${history_html(value.content)}")))),
		],
	),
)

## Compare only observable engine-authored structure and retained opaque source,
## independently of renderer parsing, engine ids and recycled model indices.
history_snapshot : Dom.Model, U64 -> Str
history_snapshot = |dom, index| {
	entry = Dom.node(dom, index)
	Str.inspect({ tag: entry.tag, text: entry.text, attrs: entry.attrs, props: entry.props, children: entry.kids.map(|child| history_snapshot(dom, child)) })
}

## Every generated HTML update history settles and equals a fresh mount. Equal
## writes emit no patch; row moves keep the same scopes, and disposal releases
## ordinary wrapper ownership. The enclosing target checks allocation balance.
unsafe_html_history : List(U8) -> {}
unsafe_html_history = |operations| {
	initial = { content: 0.U64, visible: True, reversed: False }
	(ready, commands) = Core.take_cmds(Core.mount(history_view(initial)), [])
	var $engine = ready
	var $dom = Dom.apply(Dom.new({}), commands)
	var $model = initial
	for operation in operations {
		button = Dom.button_with_text($dom, "advance") ?? crash "HTML history button"
		listener = Dom.click_target($dom, button) ?? crash "HTML history route"
		(updated_engine, batch) = Core.take_cmds(Core.event($engine, listener.node, listener.handler, operation.to_str()), [])
		$engine = updated_engine
		$dom = Dom.apply($dom, batch)
		$model = history_after($model, operation)
		if operation % 4 == 1 and !batch.is_empty() {
			crash "equal opaque HTML emitted commands"
		}
		if Core.settled($engine).is_err() {
			crash "opaque HTML readers were left stale"
		}
		(_, fresh_batch) = Core.take_cmds(Core.mount(history_view($model)), [])
		fresh = Dom.apply(Dom.new({}), fresh_batch)
		if history_snapshot($dom, $dom.root) != history_snapshot(fresh, fresh.root) {
			crash "opaque HTML differs from fresh mount"
		}
	}
	{}
}

## The same property, model and saved inputs used by the standalone app and suite.
FuzzStructureProperty := [].{
	target = fuzz_target
}
