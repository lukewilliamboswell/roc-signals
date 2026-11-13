import pf.Engine exposing [Elem, In, Root, Signal, State]
import pf.Html

## Deep-nesting test app: one path that runs past 100 layer indices, with
## specs in `specs/` that pin what each write wakes there.
##
## A layer below one at index `d` takes index `d + 1`, and a reader's
## signature has bit `index % 64`, so layers 64 indices apart share a bit.
## Layers that hold nothing (`pad16`, `pad4`) push the layers the specs use
## to the indices they need:
##
## | Index | Layer |
## |---|---|
## | 1 | a `derive` of a constant, which strips its own bit from its reads |
## | 2 | the counter `a` |
## | 3 to 18 | nothing |
## | 19 | the counter `b` |
## | 20 to 51 | nothing |
## | 52 | the counter `s` |
## | 53 to 64 | nothing |
## | 65 | an answer layer counting the answers to one timer (the bit of index 1), and beside it a layer of nothing |
## | 66 | a `derive` of `s` doubled (the bit of `a`), whose body also reads `a` ("far") |
## | 67 to 82 | nothing |
## | 83 | the counter `e` (the bit of `b`) |
## | 84 to 99 | nothing |
## | 100 | a state holding two rows |
## | 101 | the rows of an `each` over it (bit 37), which also read `s` (bit 52, "seen") |
##
## Every counter, the answer layer, the derived value, the far read, the
## rows state and each row have one reader, so a click's evaluation count
## names the readers it woke, shared bits included.
DeepApp := [].{

	## A row of the deep list.
	Item : { id : Str, n : I64 }

	rows : List(DeepApp.Item)
	rows = [{ id: "x", n: 0 }, { id: "y", n: 0 }]

	## The rows with the one keyed `key` raised by one.
	bump_row : List(DeepApp.Item), Str -> List(DeepApp.Item)
	bump_row = |items, key| items.map(|it| if (it.id == key) { ..it, n: it.n + 1 } else it)

	## The context four layers of nothing below `ctx`.
	Pad4(ctx) : In(In(In(In(ctx, {}), {}), {}), {})

	## The context sixteen layers of nothing below `ctx`.
	Pad16(ctx) : Pad4(Pad4(Pad4(Pad4(ctx))))

	## `body` four layer indices deeper, below four states that hold nothing.
	pad4 : (() -> Elem(Pad4(ctx))) -> Elem(ctx)
	pad4 = |body| Engine.state({}, |_| Engine.state({}, |_| Engine.state({}, |_| Engine.state({}, |_| body()))))

	## `body` sixteen layer indices deeper.
	pad16 : (() -> Elem(Pad16(ctx))) -> Elem(ctx)
	pad16 = |body| DeepApp.pad4(|| DeepApp.pad4(|| DeepApp.pad4(|| DeepApp.pad4(body))))

	## A state handle from above four layers of nothing.
	down4 : State(ctx, s) -> State(Pad4(ctx), s)
	down4 = |st| st.lift().lift().lift().lift()

	## A state handle from above sixteen layers of nothing.
	down16 : State(ctx, s) -> State(Pad16(ctx), s)
	down16 = |st| DeepApp.down4(DeepApp.down4(DeepApp.down4(DeepApp.down4(st))))

	## A line naming a number, read by a reader with test id `name`.
	reader : Str, Signal(ctx, I64) -> Elem(ctx)
	reader = |name, v| Html.p_s(v.map(|n| "${name}=${n.to_str()}"), [Engine.test_id(name)])

	## The counter `n` named `name`: its reader and its button, above `below`.
	counter : Str, State(ctx, I64), Elem(ctx) -> Elem(ctx)
	counter = |name, n, below| Html.div(
		name,
		[
			DeepApp.reader(name, n.signal()),
			Html.button("${name}+1", [], n.update(|v| v + 1)),
			below,
		],
	)

	## Indices 1 to 19: the derive of a constant, `a`, and `b` sixteen
	## layers below it.
	view : {} -> Elem(Root)
	view = |{}| Engine.derive(
		Engine.const(0.I64),
		|_| Engine.state(
			0.I64,
			|a| DeepApp.counter("a", a, DeepApp.pad16(|| Engine.state(0.I64, |b| DeepApp.below_b(DeepApp.down16(a).lift(), b)))),
		),
	)

	## Indices 19 to 52: `b`, and `s` thirty-two layers below it.
	below_b : State(ctx, I64), State(ctx, I64) -> Elem(ctx)
	below_b = |a, b| DeepApp.counter(
		"b",
		b,
		DeepApp.pad16(|| DeepApp.pad16(|| Engine.state(0.I64, |s| DeepApp.below_s(DeepApp.down16(DeepApp.down16(a)).lift(), s)))),
	)

	## Indices 52 to 66: `s`; twelve layers below it, the answer layer and,
	## beside it under a layer of nothing, the derive of `s` doubled.
	below_s : State(ctx, I64), State(ctx, I64) -> Elem(ctx)
	below_s = |a, s| DeepApp.counter(
		"s",
		s,
		DeepApp.pad4(
			|| DeepApp.pad4(
				|| DeepApp.pad4(
					|| {
						a12 = DeepApp.down4(DeepApp.down4(DeepApp.down4(a)))
						s12 = DeepApp.down4(DeepApp.down4(DeepApp.down4(s)))
						Html.div(
							"past-64",
							[
								Engine.resource(
									Engine.const("r"),
									{ init: 0.I64, pending: |n, _| n, plan: |_| [Engine.timer(50)], resolve: |n, _, _| n + 1 },
									|answers| DeepApp.reader("answers", answers),
								),
								Engine.state({}, |_| Engine.derive(s12.lift().signal().map(|n| n * 2), |d| DeepApp.below_d(a12.lift().lift(), s12.lift().lift(), d))),
							],
						)
					},
				),
			),
		),
	)

	## Indices 66 to 100: the derived value, the far read of `a`, `e`
	## sixteen layers below, and the rows state sixteen layers below `e`.
	below_d : State(ctx, I64), State(ctx, I64), Signal(ctx, I64) -> Elem(ctx)
	below_d = |a, s, d| Html.div(
		"d",
		[
			DeepApp.reader("d", d),
			DeepApp.reader("far", a.signal()),
			DeepApp.pad16(
				|| Engine.state(
					0.I64,
					|e| DeepApp.counter(
						"e",
						e,
						DeepApp.pad16(|| Engine.state(DeepApp.rows, |rs| DeepApp.bottom(DeepApp.down16(DeepApp.down16(s).lift()).lift(), rs))),
					),
				),
			),
		],
	)

	## Indices 100 and 101: the rows state, and an `each` over it whose rows
	## also read `s`.
	bottom : State(ctx, I64), State(ctx, List(DeepApp.Item)) -> Elem(ctx)
	bottom = |s, rs| Html.div(
		"rows",
		[
			DeepApp.reader("rows", rs.signal().map(|items| items.fold(0, |sum, it| sum + it.n))),
			Html.button("Reset rows", [], rs.update(|_| DeepApp.rows)),
			Engine.each(
				rs.signal(),
				|it| it.id,
				|r| Html.li(
					[],
					[
						Html.p_s(r.field(|it| "${it.id}=${it.n.to_str()}"), [Engine.test_id_s(r.key())]),
						Html.p_s(s.lift_row().signal().map(|n| "seen=${n.to_str()}"), [Engine.test_id_s(r.key().map(|k| "seen-${k}"))]),
						Html.button("row+1", [Engine.test_id_s(r.key().map(|k| "inc-${k}"))], rs.lift_row().update_by(r.key(), DeepApp.bump_row)),
					],
				),
			),
		],
	)

	program : Engine.Program
	program = Engine.program(|| DeepApp.view({}))
}

## Bumping a row raises the row with that key and no other.
expect DeepApp.bump_row(DeepApp.rows, "y") == [{ id: "x", n: 0 }, { id: "y", n: 1 }]
