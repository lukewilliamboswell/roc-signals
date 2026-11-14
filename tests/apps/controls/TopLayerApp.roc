import pf.Engine exposing [Elem, Root]
import pf.Html

## Browser defaults and controlled echoes are exercised without application JavaScript.
TopLayerApp := [].{

	## Independent callback facts commute; neither task source changes the other's count.
	Modal : { open : Bool, closes : U64, toggles : U64 }

	## Accept the state at close delivery, including a close that follows a reopen.
	closed : Modal, Bool -> Modal
	closed = |s, open| { ..s, open, closes: s.closes + 1 }

	## Count the generic toggle independently of the close task source.
	toggled : Modal -> Modal
	toggled = |s| { ..s, toggles: s.toggles + 1 }

	view : {} -> Elem(Root)
	view = |_| Engine.state(
		{ modal: { open: False, closes: 0.U64, toggles: 0.U64 }, inline: False, ignored: False, prevent: False, pop_a: False, pop_b: False, manual: False, initial: True, rows: ["a", "b"], row_open: False, row_modal: False, requests: Engine.outbox({}), log: "" },
		|st| Engine.element(
			"section",
			[],
			[
				Html.button("Open modal", [Engine.ref("opener")], st.update(|s| { ..s, modal: { ..s.modal, open: True } })),
				Html.button("Open inline", [], st.update(|s| { ..s, inline: True })),
				Html.button("Open ignored", [], st.update(|s| { ..s, ignored: True })),
				Html.button("Open prevented", [], st.update(|s| { ..s, prevent: True })),
				Html.button("Open auto A", [], st.update(|s| { ..s, pop_a: True })),
				Html.button("Open auto B", [], st.update(|s| { ..s, pop_b: True })),
				Html.button("Open manual", [], st.update(|s| { ..s, manual: True })),
				Html.button("Outside", [], st.update(|s| { ..s, log: "outside" })),
				Html.dialog(
					"Modal",
					{ open: st.signal().map(|s| s.modal.open), on_close: st.set_value(|s, open| { ..s, modal: TopLayerApp.closed(s.modal, open) }) },
					[Engine.on("toggle", st.update(|s| { ..s, modal: TopLayerApp.toggled(s.modal) }))],
					[
						Html.text_input(Engine.const("Modal first"), "text", Engine.const(""), [Engine.ref("modal-first")], Engine.does([])),
						Html.button("Close modal", [], st.update(|s| { ..s, modal: { ..s.modal, open: False } })),
						Html.button("Scroll modal", [], st.update(|s| { ..s, requests: s.requests.post(Into) })),
					],
				),
				Html.dialog(
					"Inline",
					{ open: st.signal().map(|s| s.inline), on_close: st.set_value(|s, open| { ..s, inline: open }), modal: NonModal },
					[],
					[
						Html.text_input(Engine.const("Inline first"), "text", Engine.const(""), [], Engine.does([])),
						Html.button("Close inline", [], st.update(|s| { ..s, inline: False })),
					],
				),
				Html.dialog(
					"Ignored",
					{ open: st.signal().map(|s| s.ignored), on_close: Engine.does([]) },
					[],
					[
						Html.button("Close ignored", [], st.update(|s| { ..s, ignored: False })),
					],
				),
				Html.dialog(
					"Prevented",
					{ open: st.signal().map(|s| s.prevent), on_close: st.set_value(|s, open| { ..s, prevent: open }) },
					[
						Engine.on_with("cancel", { prevent: True }, Engine.does([])),
					],
					[Html.button("Prevented inside", [], Engine.does([])), Html.button("Close prevented", [], st.update(|s| { ..s, prevent: False }))],
				),
				Html.popover("Auto A", { open: st.signal().map(|s| s.pop_a), on_toggle: st.set_value(|s, open| { ..s, pop_a: open }) }, [], [Html.button("Inside A", [], Engine.does([])), Html.button("Open B from A", [], st.update(|s| { ..s, pop_b: True }))]),
				Html.popover("Auto B", { open: st.signal().map(|s| s.pop_b), on_toggle: st.set_value(|s, open| { ..s, pop_b: open }) }, [], [Html.button("Inside B", [], Engine.does([])), Html.button("Open modal from B", [], st.update(|s| { ..s, modal: { ..s.modal, open: True } }))]),
				Html.popover("Manual", { open: st.signal().map(|s| s.manual), on_toggle: st.set_value(|s, open| { ..s, manual: open }), dismiss: Manual }, [], [Html.button("Close manual", [], st.update(|s| { ..s, manual: False }))]),
				Html.popover("Initially shown", { open: st.signal().map(|s| s.initial), on_toggle: st.set_value(|s, open| { ..s, initial: open }), dismiss: Manual }, [], [Html.button("Close initially shown", [], st.update(|s| { ..s, initial: False }))]),
				Html.button("Open row dialogs", [], st.update(|s| { ..s, row_open: True })),
				Html.button("Reverse shown rows", [], st.update(|s| { ..s, rows: s.rows.fold([], |out, key| [key].concat(out)) })),
				Html.button("Remove shown rows", [], st.update(|s| { ..s, rows: [], row_open: False })),
				Html.button("Restore shown rows", [], st.update(|s| { ..s, rows: ["a", "b"] })),
				Engine.each(
					st.signal().map(|s| s.rows),
					|key| key,
					|row| Engine.element(
						"div",
						[],
						[
							Html.dialog("Row dialog", { open: st.lift_row().signal().map(|s| s.row_open), on_close: st.lift_row().set_value(|s, open| { ..s, row_open: open }), modal: NonModal }, [Engine.test_id_s(row.key().map(|key| "dialog-${key}"))], [Engine.text_s(row.key())]),
						],
					),
				),
				Html.button("Open row modal", [], st.update(|s| { ..s, row_modal: True })),
				Engine.each(
					st.signal().map(|s| s.rows),
					|key| key,
					|row| Engine.element(
						"div",
						[],
						[
							Html.dialog(
								"Row modal",
								{ open: row.key().map2(st.lift_row().signal(), |key, s| key == "a" and s.row_modal), on_close: st.lift_row().set_value(|s, open| { ..s, row_modal: open }) },
								[Engine.test_id_s(row.key().map(|key| "modal-row-${key}"))],
								[
									Html.button("Reverse modal rows", [], st.lift_row().update(|s| { ..s, rows: s.rows.fold([], |out, key| [key].concat(out)) })),
									Html.button("Close row modal", [], st.lift_row().update(|s| { ..s, row_modal: False })),
									Html.button("Dispose modal rows", [], st.lift_row().update(|s| { ..s, rows: [], row_modal: False })),
								],
							),
						],
					),
				),
				Html.button("Scroll into target", [], st.update(|s| { ..s, requests: s.requests.post(Into) })),
				Html.button("Scroll to target", [], st.update(|s| { ..s, requests: s.requests.post(To) })),
				Html.button("Scroll missing", [], st.update(|s| { ..s, requests: s.requests.post(Missing) })),
				Html.button("Focus target in place", [], st.update(|s| { ..s, requests: s.requests.post(Focus) })),
				Html.button("Target", [Engine.ref("target")], Engine.does([])),
				Engine.on_post(
					st.signal().map(|s| s.requests),
					|request| match request {
						Into => [Engine.command(Engine.scroll_into_view("target", {})), Engine.command(FocusInPlace("target"))]
						To => [Engine.command(ScrollTo("target", { top: End, left: Px(7), behavior: Instant }))]
						Missing => [Engine.command(Engine.scroll_into_view("missing", {}))]
						Focus => [Engine.command(FocusInPlace("target"))]
					},
					Engine.ignore({}),
				),
				Html.p_s(st.signal().map(|s| "${s.modal.closes.to_str()}|${s.modal.toggles.to_str()}"), [Engine.test_id("modal-events")]),
				Html.p_s(st.signal().map(|s| s.log), [Engine.test_id("top-log")]),
			],
		),
	)
}

## Native task sources may arrive in either order; both produce the same app facts.
expect {
	opened = { open: True, closes: 0, toggles: 0 }
	closed_first = TopLayerApp.toggled(TopLayerApp.closed(opened, False))
	toggled_first = TopLayerApp.closed(TopLayerApp.toggled(opened), False)
	closed_first == toggled_first and closed_first == { open: False, closes: 1, toggles: 1 }
}

## A stale close of an already reopened dialog preserves the live open state in either order.
expect {
	reopened = { open: True, closes: 0, toggles: 0 }
	TopLayerApp.toggled(TopLayerApp.closed(reopened, True)) == TopLayerApp.closed(TopLayerApp.toggled(reopened), True)
}
