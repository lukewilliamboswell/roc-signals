import pf.Engine exposing [Elem, Handler, In, Signal, State]
import pf.Html

## Handlers test app: `Handler.also` and `Reaction.also`, one event or one
## answer running two writes in order, with specs in `specs/` that pin which
## readers each wakes.
##
## - A picker keeps its own open state private and is handed a handler by
##   its owner. Its one button closes the picker and runs the owner's
##   handler, which writes the owner's `date` state, as one event.
## - "n+1, then double" writes one counter twice in one event: the second
##   write sees the first. Its I64 arithmetic wraps so long sessions stay
##   defined after repeated doubling reaches the integer boundary.
## - "Both" writes the owner's two states in one event.
## - A timer's answer writes a count and a log through one composed
##   reaction.
## - "Raise both" writes an inner count and an outer count above it, with
##   a `derive` of the outer one between them. A text and an effect site
##   below the inner count read it with the derived value: they must see
##   the two written values together, never the new inner count beside
##   the old derived value.
## - "Raise outer and inner" writes an outer count and an inner count
##   below it, with a `derive` of the inner one below both. A text and an
##   effect site read the outer count with that derived value: the other
##   way round, and again they must never see one new and the other old.
## - "Rate" in a row writes the row's own count and the list the row is
##   drawn from, as one event. A text and an effect site in the row read
##   the row's count with the row's item: again never one new and the
##   other old.
##
## - "Close" is a button inside a branch: it writes a state of the branch
##   and the outer state that closes the branch, as one event. The state
##   it wrote is gone by the time it would settle, and the branch mounted
##   in its place has a button of its own where the closed one's was: that
##   button's handler must not run.
##
## Each state has one reader, so a click's evaluation count names exactly
## the readers it woke.
HandlersApp := [].{

	## A line naming a value, read by a reader with test id `name`.
	reader : Str, Signal(ctx, Str) -> Elem(ctx)
	reader = |name, v| Html.p_s(v.map(|s| "${name}=${s}"), [Engine.test_id(name)])

	## A packaged picker with private open state. Its owner passes down what
	## to do when a date is picked; the click closes the picker as well.
	picker : Handler(ctx) -> Elem(ctx)
	picker = |picked| Engine.state(
		True,
		|open| Html.div(
			"picker",
			[
				HandlersApp.reader("picker", open.signal().map(|o| if (o) "open" else "closed")),
				Engine.element("button", [Engine.on_click(open.update(|_| False).also(picked.lift()))], [Engine.text("Pick 3rd")]),
			],
		),
	)

	## The owner: a date and a number in two states of its own, the picker,
	## and a button that writes both states.
	owner : State(ctx, Str) -> Elem(ctx)
	owner = |date| Engine.state(
		0.I64,
		|other| Html.div(
			"owner",
			[
				HandlersApp.reader("date", date.lift().signal()),
				HandlersApp.reader("other", other.signal().map(|n| n.to_str())),
				HandlersApp.picker(date.lift().update(|_| "3rd")),
				Html.button("Both", [], date.lift().update(|d| "${d}!").also(other.update(|n| n + 1))),
			],
		),
	)

	## A counter written twice by one event.
	counter : {} -> Elem(ctx)
	counter = |_| Engine.state(
		0.I64,
		|n| Html.div(
			"counter",
			[
				HandlersApp.reader("n", n.signal().map(|v| v.to_str())),
				Html.button("n+1, then double", [], n.update(|v| v.plus_wrap(1)).also(n.update(|v| v.times_wrap(2)))),
			],
		),
	)

	## A timer whose one answer counts and logs through one reaction.
	answers : State(In(ctx, I64), I64) -> Elem(In(ctx, I64))
	answers = |count| Engine.state(
		"",
		|log| Html.div(
			"answers",
			[
				HandlersApp.reader("count", count.lift().signal().map(|v| v.to_str())),
				HandlersApp.reader("log", log.signal()),
				Engine.watch(Engine.const("tick"), |_| [Timer(10)], count.lift().on_result(|c, _, _| c + 1).also(log.on_result(|l, a, _| "${l}${a};"))),
			],
		),
	)

	## An inner count below a `derive` of an outer count. The text and the
	## effect site read the inner count with the derived value, and the
	## button writes both counts in one event. The effect site sets the
	## title and starts a timer for each pair it sees, so a pair that never
	## held would show as a second title and a second timer.
	pair : {} -> Elem(ctx)
	pair = |_| Engine.state(
		0.I64,
		|outer| Engine.derive(
			outer.signal().map(|n| n * 2),
			|doubled| Engine.state(
				0.I64,
				|inner| {
					seen = inner.signal().map2(doubled.lift(), |i, d| "${i.to_str()}/${d.to_str()}")
					Html.div(
						"pair",
						[
							HandlersApp.reader("pair", seen),
							Html.button("Raise both", [], inner.update(|n| n + 1).also(outer.lift().lift().update(|n| n + 1))),
							Engine.watch_changes(seen, |text| [Title("pair ${text}"), Timer(10)], Engine.ignore({})),
						],
					)
				},
			),
		),
	)

	## An outer count, an inner count below it, and a `derive` of the inner
	## count below both. The text and the effect site read the outer count
	## with the derived value, and the button writes both counts in one
	## event. The outer count's pass must take the inner count with it, so
	## that the derive follows before the text is read: a text of 1/0, or a
	## title and a timer for it, would be a pair that never held.
	##
	## Beside the inner count, at the same depth below the outer one, is a
	## state the button does not write, with a reader of its own: the inner
	## count joins the pass at its own site, so that reader is not woken.
	mixed : {} -> Elem(ctx)
	mixed = |_| Engine.state(
		0.I64,
		|outer| Html.div(
			"mixed",
			[
				Engine.state(0.I64, |aside| HandlersApp.reader("aside", aside.signal().map(|n| n.to_str()))),
				Engine.state(
					0.I64,
					|inner| Engine.derive(
						inner.signal().map(|n| n * 2),
						|doubled| {
							seen = outer.lift().lift().signal().map2(doubled, |o, d| "${o.to_str()}/${d.to_str()}")
							Html.div(
								"pairing",
								[
									HandlersApp.reader("mixed", seen),
									Html.button("Raise outer and inner", [], inner.lift().update(|n| n + 1).also(outer.lift().lift().update(|n| n + 1))),
									Engine.watch_changes(seen, |text| [Title("mixed ${text}"), Timer(10)], Engine.ignore({})),
								],
							)
						},
					),
				),
			],
		),
	)

	## A row of the rated list.
	Rated : { id : Str, stars : I64 }

	## The list with the row keyed `key` given one more star.
	starred : List(Rated), Str -> List(Rated)
	starred = |rows, key| rows.map(|row| if (row.id == key) { ..row, stars: row.stars + 1 } else row)

	## Rows that each keep a count of their own beside their item. A row's
	## text and its effect site read the row's count with the row's stars,
	## and its button writes the row's count and the list in one event.
	rated : {} -> Elem(ctx)
	rated = |_| Engine.state(
		[{ id: "x", stars: 0 }, { id: "y", stars: 0 }],
		|rows| Engine.element(
			"ul",
			[],
			[
				Engine.each(
					rows.signal(),
					|row| row.id,
					|r| Html.li(
						[],
						[
							Engine.state(
								0.I64,
								|clicks| {
									seen = clicks.signal().map2(r.field(|row| row.stars).lift(), |c, s| "${c.to_str()}/${s.to_str()}")
									Html.div(
										"rated",
										[
											Html.p_s(seen, [Engine.test_id_s(r.key().lift())]),
											Html.button_s(r.key().lift().map(|k| "Rate ${k}"), [], clicks.update(|n| n + 1).also(rows.lift_row().lift().update_by(r.key().lift(), HandlersApp.starred))),
											Engine.watch_changes(seen.map2(r.key().lift(), |text, k| "${k} ${text}"), |text| [Title("rated ${text}"), Timer(10)], Engine.ignore({})),
										],
									)
								},
							),
						],
					),
				),
			],
		),
	)

	## A branch whose button writes a state inside the branch and, in the
	## same event, the outer state that closes it. The other branch has a
	## button at the same place in its own block, which counts its presses.
	closing : {} -> Elem(ctx)
	closing = |_| Engine.state(
		{ shown: Open, presses: 0.I64 },
		|outer| Engine.when(
			outer.signal().map(|o| o.shown == Open),
			|| Engine.state(
				0.I64,
				|inner| Html.button("Close", [], inner.update(|n| n + 1).also(outer.lift().update(|o| { ..o, shown: Closed }))),
			),
			|| Engine.derive(
				Engine.const(0.I64),
				|_| Html.div(
					"closed",
					[
						HandlersApp.reader("presses", outer.lift().signal().map(|o| o.presses.to_str())),
						Html.button("Press", [], outer.lift().update(|o| { ..o, presses: o.presses + 1 })),
					],
				),
			),
		),
	)

	program : Engine.Program
	program = Engine.program(
		|| Html.div(
			"handlers",
			[
				HandlersApp.presses({}),
				HandlersApp.keyboard({}),
				Engine.state("none", HandlersApp.owner),
				HandlersApp.counter({}),
				Engine.state(0.I64, HandlersApp.answers),
				HandlersApp.pair({}),
				HandlersApp.rated({}),
				HandlersApp.closing({}),
				HandlersApp.mixed({}),
			],
		),
	)

	## Keyboard declarations exercise pass-over, live maps, row holes and
	## document lifetime without giving the app a second handler mechanism.
	keyboard : {} -> Elem(Engine.Root)
	keyboard = |_| Engine.state(
		{ log: "", inner: True, modal: False, row: True, value: "initial", out: Engine.outbox({}) },
		|state| {
			append = |label| state.update(|s| { ..s, log: "${s.log}${label};" })
			map = Engine.Keymap.prevent([Engine.Chord.plain("F2")])
			Engine.element(
				"section",
				[
					Engine.on_key({ keymap: Engine.const(map) }, append("outer")),
				],
				[
					Engine.element("span", [Engine.on_document_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("F4")])) }, append("shell"))], []),
					Html.p_s(state.signal().map(|s| s.log), [Engine.test_id("key-log")]),
					Engine.element("button", [Engine.test_id("key-inner"), Engine.on_key({ keymap: state.signal().map(|s| if (s.inner) Engine.Keymap.prevent([Engine.Chord.plain("F3")]) else Engine.Keymap.prevent([])) }, append("inner"))], [Engine.text("Key target")]),
					Html.button("Toggle keymap", [], state.update(|s| { ..s, inner: !s.inner })),
					Html.button("Toggle shortcut scope", [], state.update(|s| { ..s, modal: !s.modal })),
					Engine.when(state.signal().map(|s| s.modal), || Engine.element("aside", [Engine.on_document_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("F4")])) }, append("modal"))], [Engine.text("Shortcut scope")]), || Engine.text("")),
					Engine.each(Engine.const(["one", "two"]), |key| key, |row| Engine.element("button", [Engine.test_id_s(row.key().map(|key| "key-row-${key}")), Engine.on_key({ keymap: row.key().map(|key| Engine.Keymap.prevent([Engine.Chord.plain(if (key == "one") "F5" else "F6")])) }, state.lift_row().update(|s| { ..s, log: "${s.log}row;" }))], [Engine.text_s(row.key())])),
					Engine.element("input", [Html.aria_label("Keyboard text"), Engine.ref("key-value"), Engine.prop_s(Engine.Prop.value, state.signal().map(|s| s.value)), Html.on_input(state.set_value(|s, value| { ..s, value })), Engine.on_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("Escape")])) }, state.update(|s| { ..s, value: "initial", out: s.out.post(ApplyValue("key-value")) }))], []),
					Engine.on_post(state.signal().map(|s| s.out), |request| [request], Engine.ignore({})),
				],
			)
		},
	)

	## Both runners deliver the same click sequence, including pointer moves.
	## A prevented pointerdown suppresses the compatibility mouse events and
	## focus change while still delivering pointerup and click.
	presses : {} -> Elem(ctx)
	presses = |_props| Engine.state(
		"",
		|events| Html.div(
			"",
			[
				Engine.element("button", ["pointermove", "mousemove", "pointerdown", "mousedown", "focus", "pointerup", "mouseup", "click"].map(|event| Engine.on(event, events.update(|log| "${log}${event};"))).concat([Html.aria_label("Record click")]), [Engine.text("Record click")]),
				Engine.element("button", ["pointermove", "mousemove", "pointerdown", "mousedown", "focus", "pointerup", "mouseup", "click"].map(|event| Engine.on_with(event, { prevent: event == "pointerdown" }, events.update(|log| "${log}${event};"))).concat([Html.aria_label("Record prevented click")]), [Engine.text("Record prevented click")]),
				Html.p_s(events.signal(), [Engine.test_id("press-events")]),
			],
		),
	)
}

## A star goes to the row with the key and to no other.
expect HandlersApp.starred([{ id: "x", stars: 0 }, { id: "y", stars: 2 }], "y") == [{ id: "x", stars: 0 }, { id: "y", stars: 3 }]
