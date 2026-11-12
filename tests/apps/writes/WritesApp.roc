import pf.Engine exposing [Elem, State, Val]
import pf.Html

## Writes test app: one pure function decides a transition that spans cells
## and returns its writes (`Engine.handle`, `Engine.react`, `Cell.put`,
## `Cell.change`), with specs in `specs/` that pin which readers each
## decision wakes.
##
## - Cells with one reader each at the root, so a click's evaluation
##   count names exactly the cells it wrote.
## - "Swap" and "Swap, other order" exchange two cells: both writes are
##   computed from one reading, so the order of the list does not matter.
## - "Grow left" writes `left` while it is below 3 and nothing after: a
##   decision that returns no write wakes no one.
## - "Set then add" writes one cell twice in one list: a change after a
##   put sees the put.
## - "Deep" is a button in each row of an `each` two local layers down:
##   it writes two cells with no `lift`, composed with a local write.
## - A follow-up to every change of `left` logs what it finds: a reaction
##   that reads when its answer arrives.
## - "Rename" is the button of a component that takes a `State`: it is
##   handed the `profile` cell as one, and its write is a write of the cell.
## - `form` is a group of two cells that hands out a write starting both
##   again. "Start again" applies it; "Start again, counted" applies it
##   and then writes one of the group's cells, which refines the reset.
## - "Tap and score" writes a local count and the `score` cell as one
##   event, a local write composed with a decision. A text and an effect
##   site below the local count read it with a `derive` of the cell: they
##   must see the two written values together.
## - "Tap and reward" writes a local count and the `bonus` cell as one
##   event, the other way round: the `derive` is of the local count, and a
##   text and an effect site below it read the derived value with the cell.
WritesApp := [Writes].{

	Profile : { name : Str, visits : I64 }

	store = Engine.store(
		WritesApp.Writes,
		{
			left: Engine.cell(1.I64),
			right: Engine.cell(2.I64),
			total: Engine.cell(0.I64),
			log: Engine.cell(""),
			echo: Engine.cell(""),
			profile: Engine.cell({ name: "kim", visits: 0 }),
			form: {
				draft: Engine.cell(""),
				sent: Engine.cell(0.I64),
			}.Engine.Cells.with_reset(|cells, reset| { cells, reset }),
			score: Engine.cell(0.I64),
			bonus: Engine.cell(0.I64),
		}.Engine.Cells,
	)

	h = WritesApp.store.handles()

	## A line naming a value, read by a reader with test id `name`.
	reader : Str, Val(ctx, Str) -> Elem(ctx)
	reader = |name, v| Html.p_v(v.map(|s| "${name}=${s}"), [Engine.test_id(name)])

	## `left` and `right` as one reading.
	sides : {} -> Val(ctx, { left : I64, right : I64 })
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	sides = |{}| WritesApp.h.left.val().map2(WritesApp.h.right.val(), |left, right| { left, right })

	## The buttons at the root.
	buttons : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	buttons = |{}| Html.div(
		"buttons",
		[
			Html.button("Swap", [], Engine.handle_by(WritesApp.sides({}), |at, _| [WritesApp.h.left.put(at.right), WritesApp.h.right.put(at.left)])),
			Html.button("Swap, other order", [], Engine.handle_by(WritesApp.sides({}), |at, _| [WritesApp.h.right.put(at.left), WritesApp.h.left.put(at.right)])),
			Html.button("Grow left", [], Engine.handle_by(WritesApp.h.left.val(), |n, _| if (n < 3) [WritesApp.h.left.put(n + 1)] else [])),
			Html.button("Set then add", [], Engine.handle(|_| [WritesApp.h.total.put(10), WritesApp.h.total.change(|n| n + 1)])),
			Html.text_input(Engine.const("Echo"), "text", WritesApp.h.echo.val(), [], Engine.handle(|typed| [WritesApp.h.echo.put(typed)])),
		],
	)

	## Two local layers down, in each row: a button that writes a local
	## layer and two cells as one event.
	deep : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	deep = |{}| Engine.state(
		0.I64,
		|_outer| Engine.state(
			0.I64,
			|clicks| Html.div(
				"deep",
				[
					WritesApp.reader("clicks", clicks.val().map(|n| n.to_str())),
					Engine.element(
						"ul",
						[],
						[
							Engine.each(
								Engine.const(["r1", "r2"]),
								|k| k,
								|row| Engine.element(
									"li",
									[],
									[
										Engine.element(
											"button",
											[
												Engine.attr_v("aria-label", row.key().map(|k| "Deep ${k}")),
												Engine.on_click(
													clicks.lift_row().update(|n| n + 1).also(
														Engine.handle_by(row.key(), |key, _| [WritesApp.h.log.put(key), WritesApp.h.total.change(|n| n + 1)]),
													),
												),
											],
											[Engine.text("Deep")],
										),
									],
								),
							),
						],
					),
				],
			),
		),
	)

	## A component that takes a `State` and cannot tell a cell from a local
	## state: the profile's name, and a button that changes the profile.
	card : State(ctx, Profile) -> Elem(ctx)
	card = |held| Html.div(
		"card",
		[
			WritesApp.reader("name", held.val().map(|p| p.name)),
			Html.button("Rename", [], held.update(|p| { name: "lee", visits: p.visits + 1 })),
		],
	)

	## The group: a draft, how many were sent, and the two ways to start
	## again.
	form : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	form = |{}| {
		group = WritesApp.h.form
		Html.div(
			"form",
			[
				WritesApp.reader("draft", group.cells.draft.val()),
				WritesApp.reader("sent", group.cells.sent.val().map(|n| n.to_str())),
				Html.text_input(Engine.const("Draft"), "text", group.cells.draft.val(), [], Engine.handle(|typed| [group.cells.draft.put(typed)])),
				Html.button("Send", [], Engine.handle_by(group.cells.draft.val(), |draft, _| [WritesApp.h.log.put(draft), group.cells.sent.change(|n| n + 1)])),
				Html.button("Start again", [], Engine.handle(|_| [group.reset])),
				Html.button("Start again, counted", [], Engine.handle_by(group.cells.sent.val(), |sent, _| [group.reset, group.cells.sent.put(sent)])),
			],
		)
	}

	## A local count below a `derive` of the `score` cell. The text and the
	## effect site read the local count with the derived value, and the
	## button writes the local count and the cell in one event. The effect
	## site sets the title and starts a timer for each pair it sees, so a
	## pair that never held would show as a second title and a second
	## timer.
	paired : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	paired = |{}| Engine.derive(
		WritesApp.h.score.val().map(|n| n * 2),
		|doubled| Engine.state(
			0.I64,
			|taps| {
				seen = taps.val().map2(doubled.lift(), |t, d| "${t.to_str()}/${d.to_str()}")
				Html.div(
					"paired",
					[
						WritesApp.reader("paired", seen),
						Html.button("Tap and score", [], taps.update(|n| n + 1).also(Engine.handle(|_| [WritesApp.h.score.change(|n| n + 1)]))),
						Engine.on_change(seen, |text| [Title("paired ${text}"), Timer(10)], Engine.ignore({})),
					],
				)
			},
		),
	)

	## A `derive` of a local count, with the `bonus` cell read beside it.
	## The text and the effect site read the derived value with the cell,
	## and the button writes the local count and the cell in one event. The
	## root's pass for the cell must take the local count with it, so that
	## the derive follows before the text is read: a text of 0/1, or a
	## title and a timer for it, would be a pair that never held.
	rewarded : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	rewarded = |{}| Engine.state(
		0.I64,
		|taps| Engine.derive(
			taps.val().map(|n| n * 2),
			|doubled| {
				seen = doubled.map2(WritesApp.h.bonus.val(), |d, b| "${d.to_str()}/${b.to_str()}")
				Html.div(
					"rewarded",
					[
						WritesApp.reader("rewarded", seen),
						Html.button("Tap and reward", [], taps.lift().update(|n| n + 1).also(Engine.does([WritesApp.h.bonus.change(|n| n + 1)]))),
						Engine.on_change(seen, |text| [Title("rewarded ${text}"), Timer(10)], Engine.ignore({})),
					],
				)
			},
		),
	)

	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div(
		"app",
		[
			WritesApp.reader("left", WritesApp.h.left.val().map(|n| n.to_str())),
			WritesApp.reader("right", WritesApp.h.right.val().map(|n| n.to_str())),
			WritesApp.reader("total", WritesApp.h.total.val().map(|n| n.to_str())),
			WritesApp.reader("log", WritesApp.h.log.val()),
			WritesApp.reader("echo", WritesApp.h.echo.val()),
			WritesApp.reader("visits", WritesApp.h.profile.val().map(|p| p.visits.to_str())),
			WritesApp.buttons({}),
			WritesApp.deep({}),
			WritesApp.card(WritesApp.h.profile.state()),
			WritesApp.form({}),
			WritesApp.reader("score", WritesApp.h.score.val().map(|n| n.to_str())),
			WritesApp.paired({}),
			WritesApp.reader("bonus", WritesApp.h.bonus.val().map(|n| n.to_str())),
			WritesApp.rewarded({}),
			Engine.on_change(
				WritesApp.h.left.val(),
				|_| [Self],
				Engine.react_by(WritesApp.h.right.val(), |right, left, _| [WritesApp.h.log.put("left ${left.to_str()} right ${right.to_str()}")]),
			),
		],
	)

	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| WritesApp.store, |_| WritesApp.view({}))
}

## Writes computed from one reading swap two cells in either order.
expect {
	at = { left: 1, right: 2 }
	one = WritesApp.store.after([WritesApp.h.left.put(at.right), WritesApp.h.right.put(at.left)])
	other = WritesApp.store.after([WritesApp.h.right.put(at.left), WritesApp.h.left.put(at.right)])
	(one.read(WritesApp.h.left), one.read(WritesApp.h.right), other.read(WritesApp.h.left), other.read(WritesApp.h.right)) == (2, 1, 2, 1)
}

## A change after a put of the same cell sees the put.
expect WritesApp.store.after([WritesApp.h.total.put(10), WritesApp.h.total.change(|n| n + 1)]).read(WritesApp.h.total) == 11

## A group's reset starts every cell of the group again, and a write of one of them after it refines it.
expect {
	form = WritesApp.h.form
	used = WritesApp.store.after([form.cells.draft.put("hi"), form.cells.sent.put(3), WritesApp.h.total.put(7)])
	again = used.after([form.reset])
	counted = used.after([form.reset, form.cells.sent.put(3)])
	(again.read(form.cells.draft), again.read(form.cells.sent), again.read(WritesApp.h.total), counted.read(form.cells.draft), counted.read(form.cells.sent)) == ("", 0, 7, "", 3)
}

## A reset starts a cell at the value it was described with, not at the one the store was started with.
expect {
	form = WritesApp.h.form
	booted = WritesApp.store.with_initial(form.cells.draft, "from the boot data")
	(booted.read(form.cells.draft), booted.after([form.reset]).read(form.cells.draft)) == ("from the boot data", "")
}
